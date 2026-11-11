#!/usr/bin/env bash
# muse usage 명령으로 Muse 구독 사용량(5시간 창·주간 한도)을 조회한다.
# 기본 출력은 짧은 텍스트 요약이고, --json 옵션 사용 시 JSON 형식으로 출력한다.
# 인증과 조회는 muse CLI에 맡기고, 토큰을 직접 읽거나 출력하지 않는다.

set -euo pipefail

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--json]

Print the Muse subscription usage summary as text.

options:
  -h, --help         show this help message and exit
  --json             Print the complete usage result as JSON.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

json=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --json)
      json=true
      shift
      ;;
    *)
      print_help >&2
      fail "unrecognized argument: $1"
      ;;
  esac
done

for cmd in muse python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd was not found in PATH."
done

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

muse_status=0
muse usage --json > "$response_file" || muse_status=$?
if [[ "$muse_status" -ne 0 ]]; then
  fail "Could not get Muse usage (muse exit code $muse_status)."
fi

if [[ "$json" == true ]]; then
  python3 -c '
import json
import sys

with open(sys.argv[1]) as f:
    print(json.dumps(json.load(f), ensure_ascii=False, indent=2))
' "$response_file"
else
  python3 - "$response_file" <<'PY'
# 짧은 텍스트 요약을 출력한다. 시각은 이 기계의 현지 벽시각이다.
import json
import math
import sys
from datetime import datetime

MONTHS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)


def format_clock(moment):
    # "4:41 AM"처럼 시는 한 자리로, 분은 두 자리로, 오전·오후는 대문자로 적는다.
    hour = moment.hour % 12 or 12
    period = "AM" if moment.hour < 12 else "PM"
    return f"{hour}:{moment.minute:02d} {period}"


def format_window_reset(ms):
    # 5시간 창은 날짜 없이 시각만 적는다.
    reset = datetime.fromtimestamp(ms / 1000).astimezone()
    return f"Resets at {format_clock(reset)}"


def format_weekly_reset(ms):
    reset = datetime.fromtimestamp(ms / 1000).astimezone()
    return f"Resets {MONTHS[reset.month - 1]} {reset.day} at {format_clock(reset)}"


def main():
    with open(sys.argv[1]) as f:
        data = json.load(f)

    allowance = data.get("allowance")
    if not isinstance(allowance, dict):
        # 구독이 없으면 allowance 없이 사유만 온다.
        reason = data.get("reason") or "No usage limits were returned for the current Muse account."
        hint = data.get("hint")
        message = str(reason).strip()
        if hint:
            message = f"{message} {str(hint).strip()}"
        raise RuntimeError(message)

    rows = [
        ("Current", allowance.get("window"), format_window_reset),
        ("Weekly", allowance.get("weekly"), format_weekly_reset),
    ]

    lines = []
    tier = allowance.get("tier")
    if isinstance(tier, str) and tier:
        lines.append(f"Subscription · {tier}")
    else:
        lines.append("Subscription")

    for label, limit, render_reset in rows:
        # 창이 없거나 사용률이 null인 행은 표시하지 않는다.
        if not isinstance(limit, dict) or limit.get("usedPercent") is None:
            continue
        used = limit["usedPercent"]
        if isinstance(used, bool) or not isinstance(used, (int, float)):
            raise RuntimeError(f"Muse returned an invalid usage percentage for {label}.")
        resets_at = limit.get("resetsAtMs")
        if isinstance(resets_at, bool) or not isinstance(resets_at, (int, float)):
            raise RuntimeError(f"Muse returned an invalid reset time for {label}.")
        lines.append(
            f"  {label:<15}{math.floor(used)}% used · {render_reset(resets_at)}"
        )

    if len(lines) == 1:
        raise RuntimeError("No usage limits were returned for the current Muse account.")

    as_of = allowance.get("asOfMs")
    if isinstance(as_of, (int, float)) and not isinstance(as_of, bool):
        moment = datetime.fromtimestamp(as_of / 1000).astimezone()
        lines.append(f"  as of {format_clock(moment)}")

    print("\n".join(lines))


try:
    main()
except (OSError, RuntimeError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
fi
