#!/bin/bash

# Text-to-speech engine utilities for Code-Notify
# https://github.com/xuyangy/code-notify
#
# Engines: "system" (macOS `say`, default) and "elevenlabs" (cloud TTS via curl).
# Config (~/.config/code-notify/tts.json) mirrors channels.json: atomic write,
# 0600 perms, API key redacted in status. Synthesized audio is cached on disk
# so repeated phrases ("Claude completed the task") avoid repeat API calls.

TTS_CONFIG_DIR="${CODE_NOTIFY_CONFIG_DIR:-$HOME/.config/code-notify}"
TTS_CONFIG_FILE="$TTS_CONFIG_DIR/tts.json"
TTS_CACHE_DIR="${CODE_NOTIFY_CACHE_DIR:-$HOME/.cache/code-notify/tts}"

# Speech queueing state (opt-in via `cn voice queue on`). Concurrent hook
# runs (parallel agents finishing together) each spawn their own speaker
# process; with the queue enabled, a small on-disk mutex serializes the
# utterances so only one voice speaks at a time (see speak_notification).
SPEECH_STATE_DIR="${CODE_NOTIFY_SPEECH_STATE_DIR:-$HOME/.claude/notifications/state}"
SPEECH_LOCK_DIR="$SPEECH_STATE_DIR/speech.lock"
SPEECH_LAST_FILE="$SPEECH_STATE_DIR/speech-last"
SPEECH_QUEUE_FILE="${CODE_NOTIFY_SPEECH_QUEUE_FILE:-$HOME/.claude/notifications/voice-queue}"

# Flash v2.5 is the fastest/cheapest model, suited to short phrases.
TTS_DEFAULT_VOICE_ID="21m00Tcm4TlvDq8ikWAM"
TTS_DEFAULT_MODEL_ID="eleven_flash_v2_5"
TTS_DEFAULT_OUTPUT_FORMAT="mp3_44100_128"
TTS_ELEVENLABS_BASE_URL="${CODE_NOTIFY_ELEVENLABS_BASE_URL:-https://api.elevenlabs.io}"

tts_has_python3() {
    command -v python3 &> /dev/null
}

tts_has_curl() {
    command -v curl &> /dev/null
}

ensure_tts_config_dir() {
    mkdir -p "$TTS_CONFIG_DIR"
    chmod 700 "$TTS_CONFIG_DIR" 2>/dev/null || true
}

tts_default_json() {
    printf '%s\n' '{"engine":"system","elevenlabs":{}}'
}

tts_read_json() {
    if [[ -f "$TTS_CONFIG_FILE" ]]; then
        cat "$TTS_CONFIG_FILE"
    else
        tts_default_json
    fi
}

tts_write_json() {
    local json="$1"
    local tmp_file

    ensure_tts_config_dir
    tmp_file=$(mktemp "$TTS_CONFIG_DIR/.tts.XXXXXX") || return 1
    printf '%s\n' "$json" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$TTS_CONFIG_FILE"
}

tts_get_value() {
    local path="$1"

    tts_has_python3 || return 1
    TTS_JSON="$(tts_read_json)" python3 - "$path" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
try:
    data = json.loads(os.environ.get("TTS_JSON", "{}"))
except Exception:
    data = {}

value = data
for key in path:
    if isinstance(value, dict) and key in value:
        value = value[key]
    else:
        value = ""
        break

if value is None:
    value = ""
print(value)
PY
}

tts_set_value() {
    local path="$1"
    local value="$2"
    local current updated

    tts_has_python3 || { error "python3 is required to manage TTS settings"; return 1; }

    current="$(tts_read_json)"
    updated=$(TTS_JSON="$current" python3 - "$path" "$value" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
value = sys.argv[2]
try:
    data = json.loads(os.environ.get("TTS_JSON", "{}"))
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}

cursor = data
for key in path[:-1]:
    nxt = cursor.get(key)
    if not isinstance(nxt, dict):
        nxt = {}
        cursor[key] = nxt
    cursor = nxt
cursor[path[-1]] = value

print(json.dumps(data, separators=(",", ":")))
PY
) || return 1

    tts_write_json "$updated"
}

tts_get_engine() {
    local engine
    engine="$(tts_get_value "engine" 2>/dev/null || true)"
    [[ -n "$engine" ]] && printf '%s\n' "$engine" || printf '%s\n' "system"
}

tts_set_engine() {
    local engine="$1"
    case "$engine" in
        system|elevenlabs) ;;
        *)
            error "Unknown TTS engine: $engine (expected system or elevenlabs)"
            return 1
            ;;
    esac
    tts_set_value "engine" "$engine"
}

tts_elevenlabs_key() {
    # An exported ELEVENLABS_API_KEY wins over the stored config, so the secret
    # can live in the shell environment instead of plaintext in tts.json. The
    # hook inherits this from the process that launched the CLI.
    if [[ -n "${ELEVENLABS_API_KEY:-}" ]]; then
        printf '%s\n' "$ELEVENLABS_API_KEY"
        return 0
    fi
    tts_get_value "elevenlabs.api_key" 2>/dev/null || true
}

tts_elevenlabs_voice_id() {
    local v
    v="$(tts_get_value "elevenlabs.voice_id" 2>/dev/null || true)"
    [[ -n "$v" ]] && printf '%s\n' "$v" || printf '%s\n' "$TTS_DEFAULT_VOICE_ID"
}

tts_elevenlabs_model_id() {
    local m
    m="$(tts_get_value "elevenlabs.model_id" 2>/dev/null || true)"
    [[ -n "$m" ]] && printf '%s\n' "$m" || printf '%s\n' "$TTS_DEFAULT_MODEL_ID"
}

tts_elevenlabs_ready() {
    [[ "$(tts_get_engine)" == "elevenlabs" ]] || return 1
    tts_has_curl || return 1
    [[ -n "$(tts_elevenlabs_key)" ]] || return 1
    return 0
}

ensure_tts_cache_dir() {
    mkdir -p "$TTS_CACHE_DIR" 2>/dev/null || true
}

tts_cache_key() {
    local text="$1"
    local voice="$2"
    local model="$3"
    local project="${4:-}"
    local raw="${project}|${voice}|${model}|${text}"

    if command -v shasum &> /dev/null; then
        printf '%s' "$raw" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum &> /dev/null; then
        printf '%s' "$raw" | sha256sum | awk '{print $1}'
    else
        printf 'nocache-%s' "$RANDOM"
    fi
}

tts_cache_project_slug() {
    local project="${1:-project}"
    local slug=""
    local char
    local index

    # Keep paths portable without starting another process for each cache hit.
    # Consecutive punctuation/whitespace becomes one separator.
    for ((index = 0; index < ${#project}; index++)); do
        char="${project:index:1}"
        case "$char" in
            [[:alnum:]]) slug+="$char" ;;
            *) [[ "$slug" == *- ]] || slug+="-" ;;
        esac
    done
    slug="${slug#-}"
    slug="${slug%-}"
    printf '%s\n' "${slug:-project}"
}

tts_cache_path() {
    local key="$1"
    local project="${2:-}"
    local project_slug

    # No project means the phrase does not name one either (voice project
    # wording off, or `cn voice elevenlabs test`), so the entry is shared
    # across projects and its filename carries no project segment — labelling
    # it with whichever project happened to synthesize it first would be a lie.
    if [[ -z "$project" ]]; then
        printf '%s/tts-%s.mp3\n' "$TTS_CACHE_DIR" "$key"
        return 0
    fi

    project_slug="$(tts_cache_project_slug "$project")"
    printf '%s/tts-%s-%s.mp3\n' "$TTS_CACHE_DIR" "$project_slug" "$key"
}

# Build the request body via python to safely escape quotes/newlines in text.
tts_elevenlabs_payload() {
    local text="$1"
    local model="$2"

    if tts_has_python3; then
        TTS_TEXT="$text" TTS_MODEL="$model" python3 - <<'PY'
import json
import os

print(json.dumps({
    "text": os.environ.get("TTS_TEXT", ""),
    "model_id": os.environ.get("TTS_MODEL", ""),
    "voice_settings": {
        "stability": 0.5,
        "similarity_boost": 0.75,
        "style": 0.0,
        "use_speaker_boost": True,
    },
}, separators=(",", ":")))
PY
    else
        local escaped="${text//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        escaped="${escaped//$'\n'/ }"
        printf '{"text":"%s","model_id":"%s"}' "$escaped" "$model"
    fi
}

tts_elevenlabs_synthesize() {
    local text="$1"
    local out_file="$2"
    local api_key voice_id model_id payload http_code url tmp_file

    api_key="$(tts_elevenlabs_key)"
    voice_id="$(tts_elevenlabs_voice_id)"
    model_id="$(tts_elevenlabs_model_id)"

    [[ -n "$api_key" ]] || return 1
    tts_has_curl || return 1

    payload="$(tts_elevenlabs_payload "$text" "$model_id")" || return 1
    url="$TTS_ELEVENLABS_BASE_URL/v1/text-to-speech/$voice_id?output_format=$TTS_DEFAULT_OUTPUT_FORMAT"

    mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
    tmp_file=$(mktemp "${out_file}.XXXXXX") || return 1

    TTS_LAST_ERROR=""

    http_code=$(curl -X POST "$url" \
        -H "xi-api-key: $api_key" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o "$tmp_file" \
        -w "%{http_code}" \
        -m "${CODE_NOTIFY_TTS_TIMEOUT_SECONDS:-15}" \
        -s 2>/dev/null)

    if [[ "$http_code" == "200" ]] && [[ -s "$tmp_file" ]]; then
        mv "$tmp_file" "$out_file"
        return 0
    fi

    # shellcheck disable=SC2034  # read by callers in commands/global.sh
    TTS_LAST_ERROR="$(tts_extract_api_error "$http_code" "$tmp_file")"
    rm -f "$tmp_file"
    return 1
}

# Turn an ElevenLabs error response into a human-readable message. The error
# body is JSON like {"detail":{"message":"...","status":"..."}}.
tts_extract_api_error() {
    local http_code="$1"
    local body_file="$2"
    local msg=""

    if [[ -z "$http_code" || "$http_code" == "000" ]]; then
        printf 'could not reach ElevenLabs (network error or timeout)'
        return
    fi

    if [[ -s "$body_file" ]] && tts_has_python3; then
        msg="$(TTS_ERR_FILE="$body_file" python3 - <<'PY'
import json, os
try:
    with open(os.environ["TTS_ERR_FILE"]) as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
detail = data.get("detail", data)
if isinstance(detail, dict):
    print(detail.get("message", "") or detail.get("status", ""))
elif isinstance(detail, str):
    print(detail)
PY
)"
    fi

    if [[ -n "$msg" ]]; then
        printf 'HTTP %s: %s' "$http_code" "$msg"
    else
        printf 'HTTP %s from ElevenLabs' "$http_code"
    fi
}

# Make sure the phrase's synthesized audio is in the cache (synthesizing on
# miss). On success TTS_CACHED_FILE holds the cache path — handed back via a
# global rather than stdout, so callers need no command substitution: that
# subshell would discard the TTS_LAST_ERROR a failed synthesis records, and
# `cn voice elevenlabs test` reports it. Split from playback so the speech
# queue can warm the cache BEFORE taking the speech lock: a cache miss is a
# network round-trip (up to CODE_NOTIFY_TTS_TIMEOUT_SECONDS), and holding
# the lock through it would starve waiting speakers into their max-wait drop.
tts_elevenlabs_ensure_cached() {
    local text="$1"
    local project="${2:-}"
    local voice_id model_id key cache_file

    TTS_CACHED_FILE=""
    [[ -n "$text" ]] || return 1

    voice_id="$(tts_elevenlabs_voice_id)"
    model_id="$(tts_elevenlabs_model_id)"

    ensure_tts_cache_dir
    key="$(tts_cache_key "$text" "$voice_id" "$model_id" "$project")"
    cache_file="$(tts_cache_path "$key" "$project")"

    if [[ -s "$cache_file" ]]; then
        # Mark last-use time so stale cache entries can be found and pruned.
        touch "$cache_file" 2>/dev/null || true
        TTS_CACHED_FILE="$cache_file"
        return 0
    fi

    # Cache miss: serialize the fill per phrase, so simultaneous identical
    # events (the very burst the speech queue exists for) produce ONE
    # synthesis API call — the losers wait for the winner's cache entry
    # instead of each paying for their own. Concurrent DIFFERENT phrases
    # use different fill locks and still synthesize in parallel.
    local fill_lock="${cache_file}.fill"
    local fail_marker="${cache_file}.fail"
    local fail_backoff="${CODE_NOTIFY_TTS_FAIL_BACKOFF_SECONDS:-30}"
    [[ "$fail_backoff" =~ ^[0-9]+$ ]] || fail_backoff=30
    local synth_timeout="${CODE_NOTIFY_TTS_TIMEOUT_SECONDS:-15}"
    [[ "$synth_timeout" =~ ^[0-9]+$ ]] || synth_timeout=15
    local fill_ttl=$((synth_timeout + 15))
    # Wait past fill_ttl: reclaim needs age STRICTLY greater than the TTL and
    # only checks every ~2s, so a waiter that started with the burst must
    # outlive the TTL by a margin or it times out just before the reclaim
    # check that would have salvaged the phrase.
    local ticks=0 max_ticks=$(((fill_ttl + 5) * 5)) fill_stamp stampless_seen=""

    while :; do
        if [[ -s "$cache_file" ]]; then
            touch "$cache_file" 2>/dev/null || true
            TTS_CACHED_FILE="$cache_file"
            return 0
        fi
        # A phrase whose synthesis just failed must not be retried by every
        # waiter in the burst: without this, an outage or bad-key response
        # still costs one doomed request (each up to the synthesis timeout)
        # per identical event, serially. 0 disables the backoff.
        if (( fail_backoff > 0 )) &&
            tts_fill_failure_fresh "$fail_marker" "$fail_backoff"; then
            return 1
        fi
        if mkdir "$fill_lock" 2>/dev/null; then
            printf '%s' "$(date +%s)" > "$fill_lock/stamp" 2>/dev/null || true
            # Re-check after winning the lock: the previous filler may have
            # completed between our cache check and the mkdir.
            if [[ -s "$cache_file" ]]; then
                rm -rf "$fill_lock" 2>/dev/null || true
                touch "$cache_file" 2>/dev/null || true
                TTS_CACHED_FILE="$cache_file"
                return 0
            fi
            if tts_elevenlabs_synthesize "$text" "$cache_file"; then
                rm -f "$fail_marker" 2>/dev/null || true
                rm -rf "$fill_lock" 2>/dev/null || true
                TTS_CACHED_FILE="$cache_file"
                return 0
            fi
            # Record the failure (with its error, so backed-off callers still
            # report the real cause) BEFORE releasing the fill lock — waiters
            # re-check the marker before attempting their own fill, so none
            # can slip in between the release and the marker write.
            printf '%s\n%s' "$(date +%s)" "${TTS_LAST_ERROR:-}" > "$fail_marker" 2>/dev/null || true
            rm -rf "$fill_lock" 2>/dev/null || true
            return 1
        fi
        # Another process is synthesizing this exact phrase; wait for its
        # cache entry. Every ~2s, age out a fill lock abandoned by a killed
        # filler — a live fill cannot outlast the synthesis timeout. A
        # stampless lock gets the same two-strike grace as speech-lock pid
        # files: a single sighting may be a fresh filler between its mkdir
        # and its stamp write, but stampless on two checks 2s apart means
        # the write never completed.
        if (( ticks % 10 == 9 )); then
            fill_stamp=""
            if [[ -r "$fill_lock/stamp" ]]; then
                read -r fill_stamp < "$fill_lock/stamp" 2>/dev/null || true
            fi
            if [[ "$fill_stamp" =~ ^[0-9]+$ ]]; then
                stampless_seen=""
                if (( $(date +%s) - fill_stamp > fill_ttl )) &&
                    tts_fill_lock_reclaim "$fill_lock" "$fill_stamp"; then
                    # Reclaimed: retry the mkdir immediately. A failed
                    # reclaim (mutex busy) falls through to the sleep so
                    # waiters never spin on a held mutex.
                    continue
                fi
            elif [[ -n "$stampless_seen" ]]; then
                stampless_seen=""
                if tts_fill_lock_reclaim "$fill_lock" ""; then
                    continue
                fi
            else
                stampless_seen=1
            fi
        fi
        ((ticks++))
        if (( ticks >= max_ticks )); then
            return 1
        fi
        sleep 0.2
    done
}

# True when this phrase's last synthesis failed within the past $2 seconds
# (marker format: "<epoch>\n<error>"). Restores the recorded error into
# TTS_LAST_ERROR so a backed-off caller still reports the original failure.
tts_fill_failure_fresh() {
    local marker="$1"
    local backoff="$2"
    local stamp="" err=""

    [[ -r "$marker" ]] || return 1
    { read -r stamp; read -r err; } < "$marker" 2>/dev/null || true
    if [[ ! "$stamp" =~ ^[0-9]+$ ]] ||
        (( $(date +%s) - stamp > backoff )); then
        return 1
    fi
    TTS_LAST_ERROR="${err:-synthesis failed moments ago (backing off)}"
    return 0
}

# Remove a fill lock previously judged expired. Serialized through a reclaim
# mutex and conditional on the lock still holding exactly the stamp that was
# judged ($2, "" when the stamp was unreadable): several waiters can judge
# the same lock expired at once, and by the time a loser acts, the lock may
# already belong to a NEW filler — tearing that down (or renaming it aside,
# even briefly) would let two processes synthesize the same phrase. Returns
# 0 when a removal was attempted, 1 when the mutex was busy or the evidence
# changed.
tts_fill_lock_reclaim() {
    local fill_lock="$1"
    local observed_stamp="$2"
    local mutex="$fill_lock.reclaim"
    local mutex_ttl=30 mutex_stamp="" current_stamp=""

    if ! mkdir "$mutex" 2>/dev/null; then
        # Another waiter is reclaiming right now (its critical section lasts
        # microseconds). A mutex far older than that means the reclaimer was
        # killed inside; clear it so reclamation stays possible. A stampless
        # mutex gets the two-strike grace: only cleared when still stampless
        # on the next check 2s later.
        if [[ -r "$mutex/stamp" ]]; then
            read -r mutex_stamp < "$mutex/stamp" 2>/dev/null || true
        fi
        if [[ "$mutex_stamp" =~ ^[0-9]+$ ]]; then
            TTS_FILL_RECLAIM_STAMPLESS_SEEN=""
            if (( $(date +%s) - mutex_stamp > mutex_ttl )); then
                rm -rf "$mutex" 2>/dev/null || true
            fi
        elif [[ -n "${TTS_FILL_RECLAIM_STAMPLESS_SEEN:-}" ]]; then
            TTS_FILL_RECLAIM_STAMPLESS_SEEN=""
            rm -rf "$mutex" 2>/dev/null || true
        else
            TTS_FILL_RECLAIM_STAMPLESS_SEEN=1
        fi
        return 1
    fi
    TTS_FILL_RECLAIM_STAMPLESS_SEEN=""
    printf '%s' "$(date +%s)" > "$mutex/stamp" 2>/dev/null || true

    # Re-read under the mutex; remove only if the stamp is unchanged. An
    # abandoned lock cannot rewrite its own stamp, and other reclaimers are
    # excluded by the mutex, so an unchanged stamp means this is still the
    # same expired lock — a new filler would have written a fresh one.
    if [[ -r "$fill_lock/stamp" ]]; then
        read -r current_stamp < "$fill_lock/stamp" 2>/dev/null || true
    fi
    if [[ "$current_stamp" == "$observed_stamp" ]] && [[ -d "$fill_lock" ]]; then
        rm -rf "$fill_lock" 2>/dev/null || true
        rm -rf "$mutex" 2>/dev/null || true
        return 0
    fi
    rm -rf "$mutex" 2>/dev/null || true
    return 1
}

tts_elevenlabs_speak() {
    local text="$1"
    local project="${2:-}"

    [[ -n "$text" ]] || return 1
    tts_elevenlabs_ready || return 1
    tts_elevenlabs_ensure_cached "$text" "$project" || return 1
    tts_play_audio "$TTS_CACHED_FILE"
    return 0
}

# Play synthesized speech, waiting for playback to finish when the sync
# player is available: the caller may hold the speech lock, and releasing it
# before the audio ends would let the next utterance overlap this one.
tts_play_audio() {
    local audio_file="$1"

    if declare -F play_sound_sync &> /dev/null; then
        play_sound_sync "$audio_file"
    else
        play_sound "$audio_file"
    fi
}

# --- Speech queue (opt-in) ---------------------------------------------------
# `cn voice queue on` serializes concurrent speakers: one utterance at a time,
# later arrivals wait their turn, identical phrases spoken moments apart
# collapse into one, and a phrase that has waited too long is dropped (the
# banner already delivered the information; speech that late reads as a
# phantom event). Off by default — some users prefer to hear every voice
# immediately, even overlapping.

# True when concurrent speech should be queued. CODE_NOTIFY_SPEECH_SERIALIZE
# overrides the flag file in either direction so a single session can opt in
# or out without touching the persistent setting.
speech_queue_enabled() {
    case "${CODE_NOTIFY_SPEECH_SERIALIZE:-}" in
        "true"|"1"|"on") return 0 ;;
        "false"|"0"|"off") return 1 ;;
    esac
    [[ -f "$SPEECH_QUEUE_FILE" ]]
}

enable_speech_queue() {
    mkdir -p "$(dirname "$SPEECH_QUEUE_FILE")" 2>/dev/null || true
    touch "$SPEECH_QUEUE_FILE"
}

disable_speech_queue() {
    rm -f "$SPEECH_QUEUE_FILE"
}

# Acquire the cross-process speech mutex, waiting in line up to
# CODE_NOTIFY_SPEECH_MAX_WAIT_SECONDS (default 15). Returns 1 when the wait
# times out — the caller should drop its phrase rather than speak it stale.
# mkdir is atomic, and the pid file ("<pid> <acquired-epoch>") lets a later
# speaker reclaim a lock left behind by a killed one, and — past
# CODE_NOTIFY_SPEECH_LOCK_TTL_SECONDS (default 60, 0 disables) — one held by
# a hung or pid-recycled owner: no legitimate utterance lasts that long, so
# a single wedged speaker can only ever silence the queue for one TTL.
speech_lock_acquire() {
    local max_wait="${CODE_NOTIFY_SPEECH_MAX_WAIT_SECONDS:-15}"
    [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=15
    local lock_ttl="${CODE_NOTIFY_SPEECH_LOCK_TTL_SECONDS:-60}"
    [[ "$lock_ttl" =~ ^[0-9]+$ ]] || lock_ttl=60

    local waited_ticks=0 stale_ticks=0 owner lock_stamp reclaim empty_seen=""
    local max_ticks=$((max_wait * 5))

    mkdir -p "$SPEECH_STATE_DIR" 2>/dev/null || true
    while ! mkdir "$SPEECH_LOCK_DIR" 2>/dev/null; do
        ((stale_ticks++))
        if (( stale_ticks >= 10 )); then
            # Every ~2s of waiting, check whether the lock owner is still
            # alive; a speaker killed mid-utterance must not wedge the queue.
            stale_ticks=0
            owner=""
            lock_stamp=""
            reclaim=""
            if [[ -r "$SPEECH_LOCK_DIR/pid" ]]; then
                # read exits nonzero on the newline-less pid file even though
                # it populates the fields, so its status is deliberately
                # ignored.
                read -r owner lock_stamp < "$SPEECH_LOCK_DIR/pid" 2>/dev/null || true
            fi
            if [[ "$owner" =~ ^[0-9]+$ ]]; then
                empty_seen=""
                if ! kill -0 "$owner" 2>/dev/null; then
                    reclaim=1
                elif (( lock_ttl > 0 )) && [[ "$lock_stamp" =~ ^[0-9]+$ ]] &&
                    (( $(date +%s) - lock_stamp > lock_ttl )); then
                    # The owner looks alive but has held the lock far longer
                    # than any utterance: a hung `say`/`afplay`, or its pid
                    # was recycled by an unrelated process.
                    reclaim=1
                fi
            elif [[ -n "$empty_seen" ]]; then
                # Missing or unparseable pid file on two consecutive checks
                # (2s apart): the owner died before finishing that write — a
                # healthy holder writes its pid within milliseconds of mkdir,
                # so a single sighting may just be a holder mid-write and
                # must not be treated as stale.
                reclaim=1
            else
                empty_seen=1
            fi
            if [[ -n "$reclaim" ]]; then
                speech_lock_reclaim "$owner" "$lock_stamp" || true
                continue
            fi
        fi
        ((waited_ticks++))
        if (( waited_ticks >= max_ticks )); then
            return 1
        fi
        sleep 0.2
    done
    # Record THIS process, not $$: the macOS notifier calls speak_notification
    # from a backgrounded subshell whose parent hook shell exits immediately,
    # and $$ still names that dead parent there — a waiter's liveness probe
    # would judge the lock stale mid-utterance and speak over it. BASHPID is
    # the subshell's own pid (bash 4+); the exec-sh fallback covers bash 3.x
    # (macOS /bin/bash), where exec keeps the substitution shell's pid so its
    # $PPID is this process. Kept in a global so release can verify ownership
    # without re-deriving it.
    SPEECH_LOCK_OWNER_PID="${BASHPID:-$(exec sh -c 'echo "$PPID"')}"
    printf '%s %s' "$SPEECH_LOCK_OWNER_PID" "$(date +%s)" > "$SPEECH_LOCK_DIR/pid" 2>/dev/null || true
    return 0
}

# Remove a lock previously judged stale. Serialized through a reclaim mutex
# and conditional on the lock still holding exactly the evidence that was
# judged ($1 = observed owner pid, $2 = observed stamp; both "" when the pid
# file was unreadable): several waiters can judge the same lock stale at
# once, and by the time a loser acts, the stale lock may already have been
# removed and re-acquired by a live speaker — unconditional removal would
# tear that fresh lock down and let two voices overlap. Returns 0 when a
# removal was attempted, 1 when the mutex was busy or the evidence changed.
speech_lock_reclaim() {
    local observed_owner="$1"
    local observed_stamp="$2"
    local mutex="$SPEECH_LOCK_DIR.reclaim"
    local mutex_ttl=30 mutex_stamp="" owner="" lock_stamp=""

    if ! mkdir "$mutex" 2>/dev/null; then
        # Another waiter is reclaiming right now (its critical section lasts
        # microseconds). A mutex far older than that means the reclaimer was
        # killed inside; clear it so reclamation stays possible. A mutex
        # with no stamp yet gets the same two-strike grace as pid files:
        # only cleared when still stampless on the next check 2s later.
        if [[ -r "$mutex/stamp" ]]; then
            read -r mutex_stamp < "$mutex/stamp" 2>/dev/null || true
        fi
        if [[ "$mutex_stamp" =~ ^[0-9]+$ ]]; then
            SPEECH_RECLAIM_STAMPLESS_SEEN=""
            if (( $(date +%s) - mutex_stamp > mutex_ttl )); then
                rm -rf "$mutex" 2>/dev/null || true
            fi
        elif [[ -n "${SPEECH_RECLAIM_STAMPLESS_SEEN:-}" ]]; then
            SPEECH_RECLAIM_STAMPLESS_SEEN=""
            rm -rf "$mutex" 2>/dev/null || true
        else
            SPEECH_RECLAIM_STAMPLESS_SEEN=1
        fi
        return 1
    fi
    SPEECH_RECLAIM_STAMPLESS_SEEN=""
    printf '%s' "$(date +%s)" > "$mutex/stamp" 2>/dev/null || true

    # Re-read under the mutex; remove only if the evidence is unchanged. A
    # dead owner cannot release, and other reclaimers are excluded by the
    # mutex, so unchanged evidence means this is still the same stale lock.
    if [[ -r "$SPEECH_LOCK_DIR/pid" ]]; then
        read -r owner lock_stamp < "$SPEECH_LOCK_DIR/pid" 2>/dev/null || true
    fi
    if [[ "$owner" == "$observed_owner" ]] && [[ "$lock_stamp" == "$observed_stamp" ]]; then
        rm -f "$SPEECH_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$SPEECH_LOCK_DIR" 2>/dev/null || true
        rm -rf "$mutex" 2>/dev/null || true
        return 0
    fi
    rm -rf "$mutex" 2>/dev/null || true
    return 1
}

speech_lock_release() {
    # Only a positively confirmed owner may release: a speaker whose lock was
    # TTL-reclaimed must not tear down the lock its reclaimer (or a newer
    # speaker whose pid file isn't written yet) now holds — that would let a
    # third voice start over the second. If our own pid write failed, the
    # lock is deliberately left behind; waiters reclaim it via the stale
    # path within ~2s.
    local owner="" _rest=""
    [[ -r "$SPEECH_LOCK_DIR/pid" ]] || return 0
    read -r owner _rest < "$SPEECH_LOCK_DIR/pid" 2>/dev/null || true
    [[ -n "${SPEECH_LOCK_OWNER_PID:-}" ]] && [[ "$owner" == "$SPEECH_LOCK_OWNER_PID" ]] || return 0
    rm -f "$SPEECH_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$SPEECH_LOCK_DIR" 2>/dev/null || true
}

# True when this exact phrase started speaking within the dedup window —
# parallel sub-agents finishing together produce the same completion phrase,
# and hearing it once is enough. 0 disables deduplication.
speech_is_duplicate() {
    local text="$1"
    local window="${CODE_NOTIFY_SPEECH_DEDUP_SECONDS:-10}"
    [[ "$window" =~ ^[0-9]+$ ]] || window=10
    (( window > 0 )) || return 1
    [[ -r "$SPEECH_LAST_FILE" ]] || return 1

    local line="" spoken_at last_text now age
    IFS= read -r line < "$SPEECH_LAST_FILE" 2>/dev/null || true
    spoken_at="${line%%$'\t'*}"
    last_text="${line#*$'\t'}"
    [[ "$spoken_at" =~ ^[0-9]+$ ]] || return 1
    [[ "$last_text" == "$text" ]] || return 1

    now=$(date +%s)
    age=$((now - spoken_at))
    (( age >= 0 && age <= window ))
}

# Recorded before speaking (not after) so a waiter holding the same phrase
# already sees it as a duplicate while the first speaker is mid-utterance.
speech_record_last() {
    printf '%s\t%s' "$(date +%s)" "$1" > "$SPEECH_LAST_FILE" 2>/dev/null || true
}

# Queue decisions land in the same log used to debug notification delivery.
# Created on demand: a fresh install has ~/.claude/notifications but not
# ~/.claude/logs yet, and drop decisions must not vanish silently there.
speech_log() {
    local log_dir="$HOME/.claude/logs"
    mkdir -p "$log_dir" 2>/dev/null || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [speech] $1" >> "$log_dir/notifications.log" 2>/dev/null || true
}

# Public entry point for notifier.sh. $1 = message, $2 = system voice for the
# `say` fallback used when ElevenLabs is unselected or fails, $3 = project
# name, passed ONLY when the spoken message names that project (it separates
# the cache entries and makes their filenames identifiable). Callers whose
# message is project-agnostic must pass nothing, so one cache entry — one
# synthesis — serves every project.
# With the speech queue enabled, concurrent callers speak one at a time.
speak_notification() {
    local message="$1"
    local system_voice="${2:-}"
    local project="${3:-}"
    local status prefetched=""

    [[ -n "$message" ]] || return 0

    if ! speech_queue_enabled; then
        speak_notification_now "$message" "$system_voice" "$project"
        return $?
    fi

    # Warm the TTS cache BEFORE taking the lock: on a cache miss the
    # ElevenLabs synthesis is a network round-trip, and holding the lock
    # through it would starve waiting speakers into their max-wait drop.
    # With the cache warm, the lock is held for playback only. A phrase
    # dropped as a duplicate below leaves a ready cache entry for its twin.
    if tts_elevenlabs_ready; then
        if tts_elevenlabs_ensure_cached "$message" "$project" 2>/dev/null; then
            prefetched="$TTS_CACHED_FILE"
        fi
    fi

    if ! speech_lock_acquire; then
        speech_log "dropped after max wait: $message"
        return 0
    fi
    if speech_is_duplicate "$message"; then
        speech_lock_release
        speech_log "dropped duplicate: $message"
        return 0
    fi
    speech_record_last "$message"
    status=0
    if [[ -n "$prefetched" ]]; then
        tts_play_audio "$prefetched"
    elif command -v say &> /dev/null && [[ -n "$system_voice" ]]; then
        # ElevenLabs is unselected or its synthesis just failed: use the
        # same `say` fallback as the unqueued path, but never re-try the
        # network call while holding the lock.
        say -v "$system_voice" "$message"
    else
        status=1
    fi
    speech_lock_release
    return "$status"
}

# The actual engines. Both speak to completion in the foreground (see
# tts_play_audio) so a queued caller holds the lock for the full utterance.
speak_notification_now() {
    local message="$1"
    local system_voice="${2:-}"
    local project="${3:-}"

    if tts_elevenlabs_ready; then
        if tts_elevenlabs_speak "$message" "$project"; then
            return 0
        fi
    fi

    if command -v say &> /dev/null && [[ -n "$system_voice" ]]; then
        say -v "$system_voice" "$message"
        return 0
    fi

    return 1
}

tts_elevenlabs_list_voices() {
    local api_key

    api_key="$(tts_elevenlabs_key)"
    [[ -n "$api_key" ]] || { error "No ElevenLabs API key set (cn voice elevenlabs key <api-key>)"; return 1; }
    tts_has_curl || { error "curl is required to list voices"; return 1; }
    tts_has_python3 || { error "python3 is required to list voices"; return 1; }

    local response
    response=$(curl -s -m "${CODE_NOTIFY_TTS_TIMEOUT_SECONDS:-15}" \
        "$TTS_ELEVENLABS_BASE_URL/v1/voices" \
        -H "xi-api-key: $api_key" 2>/dev/null) || {
        error "Failed to reach ElevenLabs"
        return 1
    }

    TTS_VOICES_JSON="$response" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("TTS_VOICES_JSON", "{}"))
except Exception:
    print("Could not parse ElevenLabs response", file=sys.stderr)
    sys.exit(1)

voices = data.get("voices")
if not isinstance(voices, list):
    detail = data.get("detail", {})
    msg = detail.get("message") if isinstance(detail, dict) else detail
    print("ElevenLabs error: %s" % (msg or "unknown"), file=sys.stderr)
    sys.exit(1)

# professional/library voices require a paid plan to use via the API; premade
# and the account's own cloned/generated voices work on the free tier.
PAID_ONLY = {"professional", "library"}

print("%-24s %-26s %-13s %s" % ("VOICE ID", "NAME", "CATEGORY", "PLAN"))
for v in voices:
    name = (v.get("name", "") or "")[:26]
    vid = v.get("voice_id", "")
    category = v.get("category", "") or "?"
    plan = "paid only" if category in PAID_ONLY else "free ok"
    print("%-24s %-26s %-13s %s" % (vid, name, category, plan))
PY
}
