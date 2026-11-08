#!/usr/bin/env bash
# Claude Code 로그인 정보로 Claude 구독 사용량(세션·주간 한도)을 조회하고
# 선택적으로 세션 한도와 주간 한도를 각각 한 블록으로 묶은 짧은 요약을 출력한다.
# Claude Code의 /usage 화면이 호출하는 비공개 엔드포인트(/api/oauth/usage)를 그대로 사용한다.

set -euo pipefail

USAGE_URL="https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE="Claude Code-credentials"
CREDENTIALS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--summary] [--timeout SECONDS]

Print the complete Claude OAuth usage result as JSON.

options:
  -h, --help         show this help message and exit
  --summary          Print a short summary of the session and weekly limits.
  --timeout SECONDS  Maximum time to wait for a response (default: 20).
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

summary=false
timeout=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
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

# curl --max-time 형식에 맞는 양의 유한한 수만 허용한다.
if ! [[ "$timeout" =~ ^[0-9]*\.?[0-9]+$ ]] || ! awk -v t="$timeout" 'BEGIN { exit !(t > 0) }'; then
  fail "--timeout must be a positive, finite number"
fi

for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd was not found in PATH."
done

# Claude Code는 macOS에서는 키체인에, 그 외에는 설정 디렉터리의 .credentials.json에 로그인 정보를 저장한다.
# 키체인에 로그인이 있으면 파일에는 폐기된 옛 토큰이 남아 있을 수 있으므로 키체인을 먼저 본다.
read_credentials() {
  if [[ "$(uname -s)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null; then
      return 0
    fi
  fi
  if [[ -r "$CREDENTIALS_FILE" ]]; then
    cat "$CREDENTIALS_FILE"
    return 0
  fi
  return 1
}

credentials=$(read_credentials) || fail "Claude Code login was not found. Run 'claude' and log in first."

token=$(printf '%s' "$credentials" | python3 -c '
import json
import sys

try:
    token = json.load(sys.stdin)["claudeAiOauth"]["accessToken"]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
if not isinstance(token, str) or not token:
    sys.exit(1)
print(token)
') || fail "Claude Code login does not contain an OAuth access token. Run 'claude' and log in again."

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

# 토큰은 요청 헤더로만 전달하고 출력하지 않는다. 만료·폐기된 토큰은 갱신하지 않고 오류로 알린다.
curl_status=0
http_code=$(curl -s --max-time "$timeout" -o "$response_file" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "$USAGE_URL") || curl_status=$?

if [[ "$curl_status" -eq 28 ]]; then
  fail "Timed out waiting for Claude usage."
fi
if [[ "$curl_status" -ne 0 ]]; then
  fail "Could not reach $USAGE_URL (curl exit code $curl_status)."
fi

if [[ "$http_code" != "200" ]]; then
  message=$(python3 -c '
import json
import sys

try:
    with open(sys.argv[1]) as f:
        message = str(json.load(f)["error"]["message"]).strip()
except Exception:
    sys.exit(0)
if message:
    print(message if message.endswith(".") else message + ".")
' "$response_file")
  detail="Claude returned HTTP $http_code."
  if [[ -n "$message" ]]; then
    detail="Claude returned HTTP $http_code: $message"
  fi
  if [[ "$http_code" == "401" ]]; then
    detail="$detail Run 'claude' to refresh the login, then retry."
  fi
  fail "$detail"
fi

if [[ "$summary" == true ]]; then
  python3 - "$response_file" <<'PY'
# Claude Code /usage 화면(그래프 제외)과 같은 문구로 출력한다. 행 구성과 시각 표기는 Claude Code의 구현을 따른다.
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
    # Claude Code는 Intl이 돌려주는 IANA 시간대 이름(예: Asia/Seoul)을 괄호 안에 표시한다.
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
    # en-US 12시간제의 " PM"을 Claude Code처럼 공백 없는 소문자(8pm, 7:30pm)로 적고, 0분이면 분을 생략한다.
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


def collect_rows(data):
    # (그룹, 괄호 안 이름, 한도, 날짜 항상 표시 여부) 순서는 /usage 화면의 행 순서와 같다.
    rows = [
        ("session", None, data.get("five_hour"), False),
        ("week", "all models", data.get("seven_day"), True),
        ("week", "Sonnet only", data.get("seven_day_sonnet"), True),
    ]
    # 모델별 주간 한도는 limits 배열의 weekly_scoped 항목에서 가져온다.
    for limit in data.get("limits") or []:
        if not isinstance(limit, dict) or limit.get("kind") != "weekly_scoped":
            continue
        model = ((limit.get("scope") or {}).get("model") or {}).get("display_name")
        if not isinstance(model, str) or not model:
            continue
        rows.append((
            "week",
            model,
            {"utilization": limit.get("percent"), "resets_at": limit.get("resets_at")},
            True,
        ))
    return rows


def render_block(heading, entries):
    # 제목에는 괄호 안 이름을, 본문에는 같은 순서의 사용률을 쉼표로 이어 적고 초기화 시각은 중복 없이 뒤에 붙인다.
    labels = [label for label, _, _ in entries if label]
    title = heading + (f" ({', '.join(labels)})" if labels else "") + " :"
    parts = [f"{math.floor(used)}% used" for _, used, _ in entries]
    for _, _, reset in entries:
        if reset and reset not in parts:
            parts.append(reset)
    return f"{title}\n  {', '.join(parts)}"


def main():
    with open(sys.argv[1]) as f:
        data = json.load(f)

    entries = {group: [] for group, _ in GROUPS}
    for group, label, limit, always_show_date in collect_rows(data):
        # 한도가 없거나 사용률이 null인 행은 /usage 화면처럼 표시하지 않는다.
        if not isinstance(limit, dict) or limit.get("utilization") is None:
            continue
        used = limit["utilization"]
        if isinstance(used, bool) or not isinstance(used, (int, float)):
            name = f"Current {group}" + (f" ({label})" if label else "")
            raise RuntimeError(f"Claude returned an invalid usage percentage for {name}.")
        reset = None
        if limit.get("resets_at"):
            reset = format_reset(limit["resets_at"], always_show_date)
        entries[group].append((label, used, reset))

    blocks = [render_block(heading, entries[group]) for group, heading in GROUPS if entries[group]]
    if not blocks:
        raise RuntimeError("No usage limits were returned for the current Claude account.")
    print("\n\n".join(blocks))


try:
    main()
except (OSError, RuntimeError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
else
  python3 -c '
import json
import sys

with open(sys.argv[1]) as f:
    print(json.dumps(json.load(f), ensure_ascii=False, indent=2))
' "$response_file"
fi
