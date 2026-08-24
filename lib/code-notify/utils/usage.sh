#!/bin/bash

USAGE_DIR="${CODE_NOTIFY_CONFIG_DIR:-$HOME/.config/code-notify}"
USAGE_CONFIG_FILE="$USAGE_DIR/usage.json"
USAGE_STATE_FILE="$USAGE_DIR/usage-state.json"
USAGE_LOCK_DIR="$USAGE_DIR/usage.lock"
USAGE_WATCH_PID_FILE="$USAGE_DIR/usage-watch.pid"
USAGE_WATCH_LOG_FILE="$USAGE_DIR/usage-watch.log"

usage_has_python3() {
    command -v python3 >/dev/null 2>&1
}

ensure_usage_dir() {
    mkdir -p "$USAGE_DIR"
    chmod 700 "$USAGE_DIR" 2>/dev/null || true
}

usage_default_config_json() {
    printf '%s\n' '{"enabled":false,"providers":["codex","claude"],"thresholds":[20,10],"reset_reminders":[48,24,12,6,2,0.5],"reset_alerts":{"enabled":true,"voice":true,"sound":true,"sound_file":""}}'
}

usage_read_config_json() {
    if [[ -f "$USAGE_CONFIG_FILE" ]]; then
        cat "$USAGE_CONFIG_FILE"
    else
        usage_default_config_json
    fi
}

usage_write_file() {
    local target="$1"
    local content="$2"
    local tmp_file

    ensure_usage_dir
    tmp_file=$(mktemp "$USAGE_DIR/.usage.XXXXXX") || return 1
    printf '%s\n' "$content" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$target"
}

usage_write_config_json() {
    usage_write_file "$USAGE_CONFIG_FILE" "$1"
}

usage_write_state_json() {
    usage_write_file "$USAGE_STATE_FILE" "$1"
}

usage_normalize_provider() {
    case "${1:-all}" in
        ""|"all")
            printf '%s\n' "all"
            ;;
        "codex"|"claude")
            printf '%s\n' "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

usage_set_enabled() {
    local requested_provider="$1"
    local enabled="$2"
    local current updated

    usage_has_python3 || { error "python3 is required to manage usage alerts"; return 1; }
    usage_normalize_provider "$requested_provider" >/dev/null || { error "Unsupported usage provider: $requested_provider"; return 1; }

    current="$(usage_read_config_json)"
    updated=$(USAGE_JSON="$current" python3 - "$requested_provider" "$enabled" <<'PY'
import json
import os
import sys

requested, enabled_arg = sys.argv[1:3]
enabled = enabled_arg == "true"
try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

providers = data.get("providers") or ["codex", "claude"]
provider_state = data.get("provider_enabled") or {}
targets = ["codex", "claude"] if requested in ("", "all") else [requested]
for provider in targets:
    provider_state[provider] = enabled
for provider in ["codex", "claude"]:
    provider_state.setdefault(provider, enabled if requested in ("", "all") else False)

data["enabled"] = any(provider_state.get(provider, False) for provider in ["codex", "claude"])
data["providers"] = providers
data["provider_enabled"] = provider_state
data["thresholds"] = data.get("thresholds") or [20, 10]
data["reset_alerts"] = data.get("reset_alerts") or {"enabled": True, "voice": True, "sound": True, "sound_file": ""}
print(json.dumps(data, separators=(",", ":")))
PY
) || return 1
    usage_write_config_json "$updated"
}

usage_set_thresholds() {
    local thresholds="$1"
    local current updated

    usage_has_python3 || { error "python3 is required to manage usage alerts"; return 1; }
    [[ -n "$thresholds" ]] || { error "Please provide thresholds, for example: cn usage thresholds set 20,10"; return 1; }

    current="$(usage_read_config_json)"
    updated=$(USAGE_JSON="$current" python3 - "$thresholds" <<'PY'
import json
import os
import sys

raw = sys.argv[1].replace(" ", "")
try:
    thresholds = [int(item) for item in raw.split(",") if item]
except Exception:
    raise SystemExit(1)

if not thresholds or any(value < 1 or value > 99 for value in thresholds):
    raise SystemExit(1)

thresholds = sorted(set(thresholds), reverse=True)
try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

data["enabled"] = bool(data.get("enabled", False))
data["providers"] = data.get("providers") or ["codex", "claude"]
data["thresholds"] = thresholds
data["reset_alerts"] = data.get("reset_alerts") or {"enabled": True, "voice": True, "sound": True, "sound_file": ""}
print(json.dumps(data, separators=(",", ":")))
PY
) || return 1
    usage_write_config_json "$updated" || return 1
    success "Usage thresholds set: $thresholds"
}

usage_set_reset_reminders() {
    local reminder_hours="$1"
    local current updated

    usage_has_python3 || { error "python3 is required to manage usage alerts"; return 1; }
    [[ -n "$reminder_hours" ]] || { error "Please provide reset reminder hours, for example: cn usage reset-reminders set 48,24,12,6,2,0.5"; return 1; }

    current="$(usage_read_config_json)"
    updated=$(USAGE_JSON="$current" python3 - "$reminder_hours" <<'PY'
import json
import math
import os
import sys

raw = sys.argv[1].replace(" ", "")
if raw.lower() in ("off", "none"):
    reminders = []
else:
    try:
        reminders = [float(item) for item in raw.split(",") if item]
    except Exception:
        raise SystemExit(1)
    if not reminders or any(not math.isfinite(value) or value <= 0 or value > 168 for value in reminders):
        raise SystemExit(1)
    reminders = sorted(set(reminders), reverse=True)
    reminders = [int(value) if value.is_integer() else value for value in reminders]

try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

data["enabled"] = bool(data.get("enabled", False))
data["providers"] = data.get("providers") or ["codex", "claude"]
data["thresholds"] = data.get("thresholds") or [20, 10]
data["reset_reminders"] = reminders
data["reset_alerts"] = data.get("reset_alerts") or {"enabled": True, "voice": True, "sound": True, "sound_file": ""}
print(json.dumps(data, separators=(",", ":")))
PY
) || { error "Reset reminders must be comma-separated hours between 0 and 168"; return 1; }
    usage_write_config_json "$updated" || return 1

    if [[ "$reminder_hours" =~ ^([Oo][Ff][Ff]|[Nn][Oo][Nn][Ee])$ ]]; then
        success "Usage reset reminders disabled"
    else
        success "Usage reset reminders set: $reminder_hours hours"
    fi
}

usage_reset_reminders_default() {
    usage_set_reset_reminders "48,24,12,6,2,0.5"
}

usage_handle_reset_reminders_command() {
    local subcommand="${1:-status}"

    case "$subcommand" in
        "status"|"")
            usage_status
            ;;
        "set")
            usage_set_reset_reminders "${2:-}"
            ;;
        "on"|"reset")
            usage_reset_reminders_default
            ;;
        "off")
            usage_set_reset_reminders "off"
            ;;
        *)
            error "Unknown reset-reminders command: $subcommand"
            show_usage_help
            return 1
            ;;
    esac
}

usage_set_reset_alert_field() {
    local field="$1"
    local value="$2"
    local current updated

    usage_has_python3 || { error "python3 is required to manage usage alerts"; return 1; }

    current="$(usage_read_config_json)"
    updated=$(USAGE_JSON="$current" python3 - "$field" "$value" <<'PY'
import json
import os
import sys

field, value = sys.argv[1:3]
try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

reset_alerts = data.get("reset_alerts") or {}
reset_alerts.setdefault("enabled", True)
reset_alerts.setdefault("voice", True)
reset_alerts.setdefault("sound", True)
reset_alerts.setdefault("sound_file", "")

if field in ("enabled", "voice", "sound"):
    reset_alerts[field] = value == "true"
elif field == "sound_file":
    reset_alerts[field] = value
else:
    raise SystemExit(1)

data["enabled"] = bool(data.get("enabled", False))
data["providers"] = data.get("providers") or ["codex", "claude"]
data["thresholds"] = data.get("thresholds") or [20, 10]
data["reset_alerts"] = reset_alerts
print(json.dumps(data, separators=(",", ":")))
PY
) || return 1
    usage_write_config_json "$updated"
}

usage_get_reset_alert_field() {
    local field="$1"
    usage_has_python3 || return 1
    USAGE_JSON="$(usage_read_config_json)" python3 - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

reset_alerts = data.get("reset_alerts") or {}
defaults = {"enabled": True, "voice": True, "sound": True, "sound_file": ""}
value = reset_alerts.get(field, defaults.get(field, ""))
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

usage_reset_alerts_status() {
    local enabled voice sound sound_file
    enabled="$(usage_get_reset_alert_field enabled 2>/dev/null || echo true)"
    voice="$(usage_get_reset_alert_field voice 2>/dev/null || echo true)"
    sound="$(usage_get_reset_alert_field sound 2>/dev/null || echo true)"
    sound_file="$(usage_get_reset_alert_field sound_file 2>/dev/null || true)"

    echo "  Reset alerts: $([[ "$enabled" == "true" ]] && printf "${GREEN}ENABLED${RESET}" || printf "${DIM}DISABLED${RESET}")"
    echo "  Reset voice: $([[ "$voice" == "true" ]] && printf "${GREEN}ENABLED${RESET}" || printf "${DIM}DISABLED${RESET}")"
    if [[ "$sound" == "true" ]]; then
        if [[ -n "$sound_file" ]]; then
            echo "  Reset sound: ${GREEN}ENABLED${RESET} ($sound_file)"
        else
            echo "  Reset sound: ${GREEN}ENABLED${RESET} (distinct default)"
        fi
    else
        echo "  Reset sound: ${DIM}DISABLED${RESET}"
    fi
}

usage_set_reset_sound_file() {
    local sound_path="$1"

    [[ -n "$sound_path" ]] || { error "Please provide a sound file path"; return 1; }
    sound_path="${sound_path/#\~/$HOME}"
    [[ -f "$sound_path" ]] || { error "Sound file not found: $sound_path"; return 1; }
    usage_set_reset_alert_field sound_file "$sound_path" || return 1
    usage_set_reset_alert_field sound true || return 1
    success "Usage reset sound set: $sound_path"
}

usage_handle_reset_alerts_command() {
    local subcommand="${1:-status}"
    shift || true

    case "$subcommand" in
        "status"|"")
            usage_reset_alerts_status
            ;;
        "on")
            usage_set_reset_alert_field enabled true && success "Usage reset alerts enabled"
            ;;
        "off")
            usage_set_reset_alert_field enabled false && success "Usage reset alerts disabled"
            ;;
        "voice")
            case "${1:-status}" in
                "on") usage_set_reset_alert_field voice true && success "Usage reset voice enabled" ;;
                "off") usage_set_reset_alert_field voice false && success "Usage reset voice disabled" ;;
                *) usage_reset_alerts_status ;;
            esac
            ;;
        "sound")
            case "${1:-status}" in
                "on") usage_set_reset_alert_field sound true && success "Usage reset sound enabled" ;;
                "off") usage_set_reset_alert_field sound false && success "Usage reset sound disabled" ;;
                "set") usage_set_reset_sound_file "${2:-}" ;;
                "default") usage_set_reset_alert_field sound_file "" && usage_set_reset_alert_field sound true && success "Usage reset sound reset to distinct default" ;;
                *) usage_reset_alerts_status ;;
            esac
            ;;
        *)
            error "Unknown reset-alerts command: $subcommand"
            show_usage_help
            return 1
            ;;
    esac
}

usage_reset_thresholds() {
    usage_set_thresholds "20,10"
}

usage_reset_state() {
    usage_write_state_json '{"thresholds":{},"resets":{},"reminders":{}}'
    success "Usage alert state reset"
}

usage_emit_enabled_providers() {
    usage_has_python3 || return 0
    USAGE_JSON="$(usage_read_config_json)" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

if not data.get("enabled", False):
    raise SystemExit(0)

providers = data.get("providers") or ["codex", "claude"]
provider_state = data.get("provider_enabled") or {}
for provider in providers:
    default_enabled = not provider_state
    if provider in ("codex", "claude") and provider_state.get(provider, default_enabled):
        print(provider)
PY
}

usage_is_provider_enabled() {
    local provider="$1"
    usage_emit_enabled_providers | grep -qx "$provider"
}

usage_status() {
    local line count=0

    header "${BELL} Usage Alerts"
    echo ""

    if ! usage_has_python3; then
        echo "  ${WARNING} python3 not found; usage alerts unavailable"
        return 0
    fi

    USAGE_JSON="$(usage_read_config_json)" python3 - <<'PY' | while IFS=$'\t' read -r kind value extra; do
import json
import os
import sys

try:
    data = json.loads(os.environ.get("USAGE_JSON", "{}"))
except Exception:
    data = {}

print("enabled\t" + ("true" if data.get("enabled", False) else "false"))
print("thresholds\t" + ",".join(str(v) for v in data.get("thresholds", [20, 10])))
reminders = data["reset_reminders"] if "reset_reminders" in data else [48, 24, 12, 6, 2, 0.5]
if not isinstance(reminders, (list, tuple)):
    reminders = []
reminder_labels = []
for value in reminders:
    try:
        hours = float(value)
    except Exception:
        continue
    if not (hours > 0 and hours < float("inf")):
        continue
    if hours == 0.5:
        reminder_labels.append("30m")
    elif hours.is_integer():
        reminder_labels.append(f"{int(hours)}h")
    else:
        reminder_labels.append(f"{hours:g}h")
print("reset_reminders\t" + ",".join(reminder_labels))
reset_alerts = data.get("reset_alerts") or {}
print("reset_alerts\t" + ("true" if reset_alerts.get("enabled", True) else "false"))
print("reset_voice\t" + ("true" if reset_alerts.get("voice", True) else "false"))
print("reset_sound\t" + ("true" if reset_alerts.get("sound", True) else "false"))
providers = data.get("providers") or ["codex", "claude"]
provider_state = data.get("provider_enabled") or {}
for provider in ["codex", "claude"]:
    default_enabled = not provider_state
    enabled = data.get("enabled", False) and provider in providers and provider_state.get(provider, default_enabled)
    print("\t".join(["provider", provider, "true" if enabled else "false"]))
PY
        case "$kind" in
            enabled)
                if [[ "$value" == "true" ]]; then
                    echo "  Status: ${GREEN}ENABLED${RESET}"
                else
                    echo "  Status: ${DIM}DISABLED${RESET}"
                fi
                ;;
            thresholds)
                echo "  Thresholds: ${CYAN}$value${RESET}"
                ;;
            reset_reminders)
                if [[ -n "$value" ]]; then
                    echo "  Reset reminders: ${GREEN}ENABLED${RESET} (${CYAN}$value${RESET})"
                else
                    echo "  Reset reminders: ${DIM}DISABLED${RESET}"
                fi
                ;;
            reset_alerts)
                if [[ "$value" == "true" ]]; then
                    echo "  Reset alerts: ${GREEN}ENABLED${RESET}"
                else
                    echo "  Reset alerts: ${DIM}DISABLED${RESET}"
                fi
                ;;
            reset_voice)
                echo "  Reset voice: $([[ "$value" == "true" ]] && printf "${GREEN}ENABLED${RESET}" || printf "${DIM}DISABLED${RESET}")"
                ;;
            reset_sound)
                echo "  Reset sound: $([[ "$value" == "true" ]] && printf "${GREEN}ENABLED${RESET}" || printf "${DIM}DISABLED${RESET}")"
                ;;
            provider)
                count=$((count + 1))
                if [[ "$extra" == "true" ]]; then
                    echo "  ${CHECK_MARK} $value: ${GREEN}ENABLED${RESET}"
                else
                    echo "  ${MUTE} $value: ${DIM}DISABLED${RESET}"
                fi
                ;;
        esac
    done

    echo ""
    usage_watch_status_line
    echo "  ${DIM}Usage alerts use local Codex/Claude auth files and provider usage endpoints.${RESET}"
}

usage_load_codex_token() {
    local auth_file="${CODEX_HOME:-$HOME/.codex}/auth.json"
    [[ -f "$auth_file" ]] || return 1
    usage_has_python3 || return 1
    python3 - "$auth_file" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    token = data.get("tokens", {}).get("access_token", "")
except Exception:
    token = ""

if token:
    print(token, end="")
else:
    raise SystemExit(1)
PY
}

usage_load_claude_token() {
    local credentials_file="${CLAUDE_HOME:-$HOME/.claude}/.credentials.json"
    [[ -f "$credentials_file" ]] || return 1
    usage_has_python3 || return 1
    python3 - "$credentials_file" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    token = data.get("claudeAiOauth", {}).get("accessToken", "")
except Exception:
    token = ""

if token:
    print(token, end="")
else:
    raise SystemExit(1)
PY
}

usage_fetch_codex_quota() {
    local token payload
    token="$(usage_load_codex_token)" || return 2
    command -v curl >/dev/null 2>&1 || return 3

    payload=$(curl -fsS -m "${CODE_NOTIFY_USAGE_TIMEOUT_SECONDS:-5}" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer $token" \
        "https://chatgpt.com/backend-api/wham/usage" 2>/dev/null) || return 4

    USAGE_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("USAGE_PAYLOAD", "{}"))
    primary = data["rate_limit"]["primary_window"]
    secondary = data["rate_limit"]["secondary_window"]
except Exception:
    raise SystemExit(1)

for name, window in (("5h", primary), ("7d", secondary)):
    used = round(float(window["used_percent"]))
    remaining = max(0, min(100, 100 - int(used)))
    reset_at = str(window.get("reset_at", ""))
    print("\t".join(["codex", name, str(remaining), reset_at]))
PY
}

usage_fetch_claude_quota() {
    local token payload
    token="$(usage_load_claude_token)" || return 2
    command -v curl >/dev/null 2>&1 || return 3

    payload=$(curl -fsS -m "${CODE_NOTIFY_USAGE_TIMEOUT_SECONDS:-5}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/1.0" \
        -H "Authorization: Bearer $token" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 4

    USAGE_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("USAGE_PAYLOAD", "{}"))
    windows = [("5h", data["five_hour"]), ("7d", data["seven_day"])]
except Exception:
    raise SystemExit(1)

for name, window in windows:
    used = round(float(window["utilization"]))
    remaining = max(0, min(100, 100 - int(used)))
    reset_at = str(window.get("resets_at") or "")
    print("\t".join(["claude", name, str(remaining), reset_at]))
PY
}

usage_fetch_provider_quota() {
    case "$1" in
        codex)
            usage_fetch_codex_quota
            ;;
        claude)
            usage_fetch_claude_quota
            ;;
        *)
            return 1
            ;;
    esac
}

usage_state_events() {
    local quota_lines="$1"
    local config state updated_output

    usage_has_python3 || return 1
    config="$(usage_read_config_json)"
    if [[ -f "$USAGE_STATE_FILE" ]]; then
        state="$(cat "$USAGE_STATE_FILE")"
    else
        state='{"thresholds":{},"resets":{},"reminders":{}}'
    fi

    updated_output=$(python3 - "$config" "$state" "$quota_lines" <<'PY'
import json
import math
import os
import sys
import time
from datetime import datetime, timezone


def parse_reset_epoch(value):
    if not value or value == "null":
        return None
    try:
        epoch = float(value)
        if not math.isfinite(epoch):
            return None
        if epoch > 10_000_000_000:
            epoch /= 1000
        return epoch
    except (TypeError, ValueError):
        pass
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp()
    except (TypeError, ValueError):
        return None


def hour_marker(value):
    return str(int(value)) if float(value).is_integer() else f"{value:g}"

config = json.loads(sys.argv[1] or "{}")
try:
    state = json.loads(sys.argv[2] or "{}")
except Exception:
    state = {}
quota_lines = sys.argv[3].splitlines()
thresholds = sorted({int(v) for v in config.get("thresholds", [20, 10])}, reverse=True)
reset_reminders = []
configured_reminders = config["reset_reminders"] if "reset_reminders" in config else [48, 24, 12, 6, 2, 0.5]
if not isinstance(configured_reminders, (list, tuple)):
    configured_reminders = []
for value in configured_reminders:
    try:
        hours = float(value)
    except (TypeError, ValueError):
        continue
    if math.isfinite(hours) and 0 < hours <= 168:
        reset_reminders.append(hours)
reset_reminders = sorted(set(reset_reminders), reverse=True)
try:
    now_epoch = float(os.environ.get("CODE_NOTIFY_USAGE_NOW_EPOCH", time.time()))
except (TypeError, ValueError):
    now_epoch = time.time()
state.setdefault("thresholds", {})
state.setdefault("resets", {})
state.setdefault("reminders", {})
events = []

for line in quota_lines:
    if not line.strip():
        continue
    provider, window, remaining_raw, reset_at = (line.split("\t") + [""])[:4]
    remaining = int(float(remaining_raw))
    reset_key = f"{provider}:{window}"
    reset_entry = state["resets"].get(reset_key)
    had_previous_reset_state = isinstance(reset_entry, dict) and "full" in reset_entry
    was_full = bool(reset_entry.get("full", False)) if isinstance(reset_entry, dict) else False
    if remaining >= 100:
        if had_previous_reset_state and not was_full:
            events.append(["reset", provider, window, str(remaining), reset_at, "100"])
        state["resets"][reset_key] = {"full": True}
    else:
        state["resets"][reset_key] = {"full": False}

    reset_epoch = parse_reset_epoch(reset_at)
    if remaining >= 100:
        state["reminders"].pop(reset_key, None)
    elif reset_epoch is not None and reset_epoch > now_epoch and reset_reminders:
        window_span_hours = {"5h": 5, "7d": 168}.get(window)
        applicable = [value for value in reset_reminders if window_span_hours is None or value <= window_span_hours]
        seconds_until_reset = reset_epoch - now_epoch
        due = [value for value in applicable if seconds_until_reset <= value * 3600]

        reminder_entry = state["reminders"].get(reset_key)
        same_cycle = False
        notified = set()
        if isinstance(reminder_entry, dict):
            try:
                same_cycle = abs(float(reminder_entry.get("reset_epoch", 0)) - reset_epoch) <= 900
            except (TypeError, ValueError):
                same_cycle = False
            if same_cycle:
                for value in reminder_entry.get("hours", []):
                    try:
                        notified.add(float(value))
                    except (TypeError, ValueError):
                        pass

        unseen_due = [value for value in due if value not in notified]
        if unseen_due:
            marker = min(unseen_due)
            events.append(["reset_reminder", provider, window, str(remaining), reset_at, hour_marker(marker)])
            notified.update(due)
        state["reminders"][reset_key] = {
            "reset_epoch": reset_epoch,
            "hours": sorted(notified, reverse=True),
        }

    for threshold in thresholds:
        key = f"{provider}:{window}:{threshold}"
        was_below = bool(state["thresholds"].get(key, {}).get("below", False))
        if remaining <= threshold:
            if not was_below:
                events.append(["threshold", provider, window, str(remaining), reset_at, str(threshold)])
            state["thresholds"][key] = {"below": True}
        else:
            state["thresholds"][key] = {"below": False}

print(json.dumps(state, separators=(",", ":")))
print("---EVENTS---")
for event in events:
    print("\t".join(event))
PY
) || return 1

    usage_write_state_json "$(printf '%s\n' "$updated_output" | sed '/^---EVENTS---$/,$d')"
    printf '%s\n' "$updated_output" | sed '1,/^---EVENTS---$/d'
}

usage_notifier_path() {
    local usage_dir
    usage_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "$usage_dir/../core/notifier.sh"
}

usage_display_name() {
    case "$1" in
        codex) printf '%s\n' "Codex" ;;
        claude) printf '%s\n' "Claude" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

usage_window_label() {
    case "$1" in
        "5h") printf '%s\n' "daily (5h)" ;;
        "7d") printf '%s\n' "weekly (7d)" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

usage_window_voice_label() {
    case "$1" in
        "5h") printf '%s\n' "daily limit" ;;
        "7d") printf '%s\n' "weekly limit" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

usage_reset_reminder_label() {
    case "$1" in
        "0.5") printf '%s\n' "30 minutes" ;;
        "1") printf '%s\n' "1 hour" ;;
        *) printf '%s\n' "$1 hours" ;;
    esac
}

usage_send_event() {
    local kind="$1"
    local provider="$2"
    local window="$3"
    local remaining="$4"
    local reset_at="$5"
    local marker="$6"
    local title message voice_message notifier display_name window_label window_voice_label reminder_label reset_enabled reset_voice reset_sound reset_sound_file hook_type

    display_name="$(usage_display_name "$provider")"
    window_label="$(usage_window_label "$window")"
    window_voice_label="$(usage_window_voice_label "$window")"

    case "$kind" in
        reset)
            reset_enabled="$(usage_get_reset_alert_field enabled 2>/dev/null || echo true)"
            [[ "$reset_enabled" == "true" ]] || return 0
            reset_voice="$(usage_get_reset_alert_field voice 2>/dev/null || echo true)"
            reset_sound="$(usage_get_reset_alert_field sound 2>/dev/null || echo true)"
            reset_sound_file="$(usage_get_reset_alert_field sound_file 2>/dev/null || true)"
            title="$display_name token $window_voice_label reset"
            message="$display_name $window_label tokens have reset. Usage is back to 100%."
            voice_message="$display_name token $window_voice_label reset. You can use $display_name again."
            hook_type="usage_reset"
            ;;
        threshold)
            title="$display_name usage low"
            message="$display_name $window_label remaining usage is ${remaining}% (threshold ${marker}%)."
            voice_message="$display_name usage is low"
            hook_type="usage"
            ;;
        reset_reminder)
            reminder_label="$(usage_reset_reminder_label "$marker")"
            title="$display_name $window_voice_label reset soon"
            message="$display_name $window_label resets in under $reminder_label. ${remaining}% remains; use it before the reset."
            voice_message="$display_name $window_voice_label resets in under $reminder_label"
            hook_type="usage"
            ;;
        *)
            return 0
            ;;
    esac

    if [[ "$kind" != "reset_reminder" && -n "$reset_at" && "$reset_at" != "null" ]]; then
        message="$message Reset: $reset_at"
    fi

    notifier="$(usage_notifier_path)"
    if [[ -x "$notifier" || -f "$notifier" ]]; then
        CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_USAGE_TITLE="$title" \
        CODE_NOTIFY_USAGE_MESSAGE="$message" \
        CODE_NOTIFY_USAGE_VOICE_MESSAGE="$voice_message" \
        CODE_NOTIFY_USAGE_CONTEXT="Usage: $provider $window_label ${remaining}%" \
        CODE_NOTIFY_USAGE_RESET_VOICE="${reset_voice:-}" \
        CODE_NOTIFY_USAGE_RESET_SOUND="${reset_sound:-}" \
        CODE_NOTIFY_USAGE_RESET_SOUND_FILE="${reset_sound_file:-}" \
        bash "$notifier" "$hook_type" "$provider" "$window" >/dev/null 2>&1 || true
    fi
}

usage_check_provider() {
    local provider="$1"
    local quota_lines events event kind window remaining reset_at marker

    quota_lines="$(usage_fetch_provider_quota "$provider" 2>/dev/null)" || return 0
    [[ -n "$quota_lines" ]] || return 0
    events="$(usage_state_events "$quota_lines")" || return 0

    while IFS=$'\t' read -r kind provider window remaining reset_at marker; do
        [[ -n "$kind" ]] || continue
        usage_send_event "$kind" "$provider" "$window" "$remaining" "$reset_at" "$marker"
    done <<< "$events"
}

usage_check() {
    local requested="${1:-all}"
    local provider normalized

    normalized="$(usage_normalize_provider "$requested")" || { error "Unsupported usage provider: $requested"; return 1; }

    if [[ "$normalized" == "all" ]]; then
        while read -r provider; do
            usage_check_provider "$provider"
        done < <(usage_emit_enabled_providers)
    else
        usage_is_provider_enabled "$normalized" || return 0
        usage_check_provider "$normalized"
    fi
}

usage_check_with_lock() {
    ensure_usage_dir
    if mkdir "$USAGE_LOCK_DIR" 2>/dev/null; then
        trap 'rmdir "$USAGE_LOCK_DIR" 2>/dev/null || true' RETURN
        usage_check "$@"
        rmdir "$USAGE_LOCK_DIR" 2>/dev/null || true
        trap - RETURN
    fi
}

usage_watch() {
    local requested="${1:-all}"
    local interval="${2:-300}"

    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        error "Interval must be a number of seconds"
        return 1
    fi
    if [[ "$interval" -lt 60 ]]; then
        interval=60
    fi

    info "Watching usage every ${interval}s. Press Ctrl-C to stop."
    while true; do
        usage_check "$requested"
        sleep "$interval"
    done
}

usage_command_path() {
    if [[ -n "${CODE_NOTIFY_MAIN_SCRIPT:-}" && -f "${CODE_NOTIFY_MAIN_SCRIPT:-}" ]]; then
        printf '%s\n' "$CODE_NOTIFY_MAIN_SCRIPT"
        return 0
    fi
    if command -v code-notify >/dev/null 2>&1; then
        command -v code-notify
        return 0
    fi
    if command -v cn >/dev/null 2>&1; then
        command -v cn
        return 0
    fi
    return 1
}

usage_watch_pid() {
    [[ -f "$USAGE_WATCH_PID_FILE" ]] || return 1
    sed -n '1p' "$USAGE_WATCH_PID_FILE" 2>/dev/null | tr -cd '0-9'
}

usage_watch_is_running() {
    local pid
    pid="$(usage_watch_pid)" || return 1
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

usage_watch_status_line() {
    local pid
    if usage_watch_is_running; then
        pid="$(usage_watch_pid)"
        echo "  Watcher: ${GREEN}RUNNING${RESET} (pid $pid)"
    else
        echo "  Watcher: ${DIM}STOPPED${RESET}"
    fi
}

usage_watch_status() {
    header "${BELL} Usage Watcher"
    echo ""
    usage_watch_status_line
    echo "  Log: ${DIM}$USAGE_WATCH_LOG_FILE${RESET}"
}

usage_watch_start() {
    local requested="${1:-all}"
    local interval="${2:-300}"
    local normalized command_path pid

    normalized="$(usage_normalize_provider "$requested")" || { error "Unsupported usage provider: $requested"; return 1; }
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        error "Interval must be a number of seconds"
        return 1
    fi
    if [[ "$interval" -lt 60 ]]; then
        interval=60
    fi

    ensure_usage_dir
    if usage_watch_is_running; then
        pid="$(usage_watch_pid)"
        success "Usage watcher already running (pid $pid)"
        return 0
    fi

    command_path="$(usage_command_path)" || { error "Could not find code-notify command for background watcher"; return 1; }
    : > "$USAGE_WATCH_LOG_FILE"
    chmod 600 "$USAGE_WATCH_LOG_FILE" 2>/dev/null || true

    nohup bash "$command_path" usage watch-run "$normalized" --interval "$interval" >> "$USAGE_WATCH_LOG_FILE" 2>&1 &
    pid="$!"
    printf '%s\n' "$pid" > "$USAGE_WATCH_PID_FILE"
    chmod 600 "$USAGE_WATCH_PID_FILE" 2>/dev/null || true

    sleep 0.2
    if usage_watch_is_running; then
        success "Usage watcher started (pid $pid, every ${interval}s)"
        info "Log: $USAGE_WATCH_LOG_FILE"
    else
        rm -f "$USAGE_WATCH_PID_FILE"
        error "Usage watcher failed to start. See: $USAGE_WATCH_LOG_FILE"
        return 1
    fi
}

usage_watch_stop() {
    local pid
    if ! usage_watch_is_running; then
        rm -f "$USAGE_WATCH_PID_FILE"
        success "Usage watcher is not running"
        return 0
    fi

    pid="$(usage_watch_pid)"
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -f "$USAGE_WATCH_PID_FILE"
    success "Usage watcher stopped"
}

usage_watch_restart() {
    local requested="${1:-all}"
    local interval="${2:-300}"
    usage_watch_stop >/dev/null 2>&1 || true
    usage_watch_start "$requested" "$interval"
}

usage_setup() {
    local requested="all"
    local interval="300"
    local start_watch="false"
    local normalized

    while [[ $# -gt 0 ]]; do
        case "$1" in
            "codex"|"claude"|"all")
                requested="$1"
                shift
                ;;
            "--watch"|"--start")
                start_watch="true"
                shift
                ;;
            "--interval")
                interval="${2:-300}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    normalized="$(usage_normalize_provider "$requested")" || { error "Unsupported usage provider: $requested"; return 1; }

    usage_set_enabled "$normalized" true || return 1
    usage_set_thresholds "20,10" >/dev/null || return 1
    usage_reset_reminders_default >/dev/null || return 1
    usage_set_reset_alert_field enabled true || return 1
    usage_set_reset_alert_field voice true || return 1
    usage_set_reset_alert_field sound true || return 1
    usage_set_reset_alert_field sound_file "" || return 1

    success "Usage reset alerts configured"
    info "Providers: $normalized"
    info "Thresholds: 20%, 10%"
    info "Reset reminders: 48h, 24h, 12h, 6h, 2h, 30m"
    info "Reset alerts: voice and distinct reset sound enabled"

    if [[ "$start_watch" == "true" ]]; then
        usage_watch_start "$normalized" "$interval"
    else
        echo ""
        dim "Run ${BOLD}cn usage watch start --interval $interval${RESET}${DIM} to keep watching in the background.${RESET}"
        dim "Run ${BOLD}cn usage check${RESET}${DIM} for a one-shot check.${RESET}"
    fi
}

usage_parse_watch_args() {
    local provider="${1:-all}"
    local interval="300"

    if [[ "$provider" == "--interval" ]]; then
        provider="all"
    else
        shift 2>/dev/null || true
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--interval")
                interval="${2:-300}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    printf '%s\t%s\n' "$provider" "$interval"
}

handle_usage_command() {
    local subcommand="${1:-status}"
    shift || true

    case "$subcommand" in
        "status"|"")
            usage_status
            ;;
        "on")
            usage_set_enabled "${1:-all}" true && success "Usage alerts enabled"
            ;;
        "off")
            usage_set_enabled "${1:-all}" false && success "Usage alerts disabled"
            ;;
        "check")
            usage_check "${1:-all}"
            ;;
        "setup")
            usage_setup "$@"
            ;;
        "watch")
            local action="${1:-}"
            local parsed provider interval
            case "$action" in
                "start")
                    shift
                    parsed="$(usage_parse_watch_args "$@")"
                    provider="${parsed%%$'\t'*}"
                    interval="${parsed#*$'\t'}"
                    usage_watch_start "$provider" "$interval"
                    ;;
                "stop")
                    usage_watch_stop
                    ;;
                "restart")
                    shift
                    parsed="$(usage_parse_watch_args "$@")"
                    provider="${parsed%%$'\t'*}"
                    interval="${parsed#*$'\t'}"
                    usage_watch_restart "$provider" "$interval"
                    ;;
                "status")
                    usage_watch_status
                    ;;
                *)
                    parsed="$(usage_parse_watch_args "$@")"
                    provider="${parsed%%$'\t'*}"
                    interval="${parsed#*$'\t'}"
                    usage_watch "$provider" "$interval"
                    ;;
            esac
            ;;
        "watch-run")
            local provider="${1:-all}"
            local interval="300"
            shift 2>/dev/null || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    "--interval")
                        interval="${2:-300}"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            usage_watch "$provider" "$interval"
            ;;
        "thresholds")
            case "${1:-status}" in
                "set")
                    usage_set_thresholds "${2:-}"
                    ;;
                "reset")
                    usage_reset_thresholds
                    ;;
                *)
                    usage_status
                    ;;
            esac
            ;;
        "reset-reminders")
            usage_handle_reset_reminders_command "$@"
            ;;
        "reset-alerts")
            usage_handle_reset_alerts_command "$@"
            ;;
        "reset-state")
            usage_reset_state
            ;;
        "help"|"-h"|"--help")
            show_usage_help
            ;;
        *)
            error "Unknown usage command: $subcommand"
            show_usage_help
            return 1
            ;;
    esac
}
