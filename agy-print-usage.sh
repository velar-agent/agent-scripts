#!/usr/bin/env bash
# agy -p "/usage" 명령으로 Antigravity 계정 사용량(세션·주간 한도)을 조회한다.
# 기본 출력은 원본 텍스트 표이며, 옵션에 따라 JSON 형식 또는 요약 블록을 출력한다.

set -euo pipefail

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--output-format-json] [--summary] [--timeout SECONDS]

Print Antigravity usage limits using 'agy -p "/usage"'.

options:
  -h, --help              show this help message and exit
  --output-format-json    Print the usage result as JSON.
  --summary               Print a short summary of the session and weekly limits.
  --timeout SECONDS       Maximum time to wait for a response (default: 20).
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

output_format_json=false
summary=false
timeout=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --output-format-json|--json)
      output_format_json=true
      shift
      ;;
    --summary)
      summary=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || fail "--timeout requires a value"
      timeout="$2"
      shift 2
      ;;
    --timeout=*)
      timeout="${1#--timeout=}"
      shift
      ;;
    *)
      print_help >&2
      fail "unrecognized argument: $1"
      ;;
  esac
done

if [[ "$output_format_json" == true && "$summary" == true ]]; then
  fail "--output-format-json and --summary cannot be used together"
fi

# agy --print-timeout 형식에 맞는 양의 유한한 수만 허용한다.
if ! [[ "$timeout" =~ ^[0-9]*\.?[0-9]+$ ]] || ! awk -v t="$timeout" 'BEGIN { exit !(t > 0) }'; then
  fail "--timeout must be a positive, finite number"
fi

for cmd in agy python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd was not found in PATH."
done

# 기본 출력: 원본 agy -p "/usage" 텍스트 표 출력
if [[ "$output_format_json" == false && "$summary" == false ]]; then
  exec agy --print-timeout "${timeout}s" -p "/usage"
fi

response_file=$(mktemp)
error_file=$(mktemp)
trap 'rm -f "$response_file" "$error_file"' EXIT

agy_status=0
agy --output-format json --print-timeout "${timeout}s" -p "/usage" > "$response_file" 2> "$error_file" || agy_status=$?

if [[ "$agy_status" -ne 0 ]]; then
  err_msg=$(cat "$error_file")
  if [[ -n "$err_msg" ]]; then
    fail "agy command failed (exit code $agy_status): $err_msg"
  else
    fail "agy command failed with exit code $agy_status."
  fi
fi

if [[ "$summary" == true ]]; then
  python3 - "$response_file" <<'PY'
# 세션 및 주간 한도를 블록으로 묶어 요약 출력한다.
import json
import math
import os
import sys
from datetime import datetime

MONTHS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)


def local_timezone_name():
    # Intl 호환 IANA 시간대 이름을 괄호 안에 표시한다.
    tz = os.environ.get("TZ", "").lstrip(":")
    if tz:
        return tz
    try:
        target = os.readlink("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    try:
        with open("/etc/timezone") as f:
            name = f.read().strip()
        if name:
            return name
    except OSError:
        pass
    return datetime.now().astimezone().tzname() or "UTC"


TIMEZONE = local_timezone_name()


def format_clock(moment):
    # 12시간제를 공백 없는 소문자(8pm, 7:30pm)로 적고, 0분이면 분을 생략한다.
    hour = moment.hour % 12 or 12
    minutes = f":{moment.minute:02d}" if moment.minute else ""
    period = "am" if moment.hour < 12 else "pm"
    return f"{hour}{minutes}{period}"


def format_reset(value, always_show_date):
    reset = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
    now = datetime.now().astimezone()
    text = format_clock(reset)
    # 주간 한도는 항상 날짜를 붙이고, 세션 한도는 초기화가 24시간 넘게 남았을 때만 붙인다.
    if always_show_date or (reset - now).total_seconds() > 24 * 3600:
        date = f"{MONTHS[reset.month - 1]} {reset.day}"
        if reset.year != now.year:
            date += f", {reset.year}"
        text = f"{date} at {text}"
    return f"Resets {text} ({TIMEZONE})"


GROUPS = (("session", "Current session"), ("week", "Current week"))


def main():
    with open(sys.argv[1]) as f:
        data = json.load(f)

    if isinstance(data, dict) and data.get("status") not in (None, "SUCCESS"):
        raise RuntimeError(f"agy command failed with status: {data.get('status')}")

    command_data = data.get("command", {}).get("data") if isinstance(data, dict) else None
    if not isinstance(command_data, dict):
        command_data = data if isinstance(data, dict) else {}

    groups = command_data.get("groups")
    if not isinstance(groups, list):
        raise RuntimeError("No quota groups found in agy usage output.")

    entries = {group: [] for group, _ in GROUPS}

    for group in groups:
        if not isinstance(group, dict):
            continue
        group_name = group.get("name") or "Unknown"
        buckets = group.get("buckets") or []
        for bucket in buckets:
            if not isinstance(bucket, dict):
                continue
            window = bucket.get("window")
            frac = bucket.get("remaining_fraction")
            if frac is None:
                continue
            used = max(0, min(100, 100 - round(frac * 100)))
            reset_time = bucket.get("reset_time")
            if window == "5h":
                reset_text = format_reset(reset_time, False) if reset_time else None
                entries["session"].append((group_name, used, reset_text))
            elif window == "weekly":
                reset_text = format_reset(reset_time, True) if reset_time else None
                entries["week"].append((group_name, used, reset_text))

    def render_block(heading, items):
        labels = [label for label, _, _ in items if label]
        title = heading + (f" ({', '.join(labels)})" if labels else "") + " :"
        parts = [f"{used}% used" for _, used, _ in items]
        for _, _, reset in items:
            if reset and reset not in parts:
                parts.append(reset)
        return f"{title}\n  {', '.join(parts)}"

    blocks = [render_block(heading, entries[group]) for group, heading in GROUPS if entries[group]]
    if not blocks:
        raise RuntimeError("No usage limits were returned by agy.")
    print("\n\n".join(blocks))


try:
    main()
except (OSError, RuntimeError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
elif [[ "$output_format_json" == true ]]; then
  python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

print(json.dumps(data, ensure_ascii=False, indent=2))
PY
fi
