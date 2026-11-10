#!/usr/bin/env bash
# Grok 로그인 정보로 구독 사용량(주간 또는 월간 한도)을 조회한다.
# 기본 출력은 /billing?format=credits 응답 JSON이다.
# --summary 는 한 줄이다. 예: Weekly limit (X Premium+), 7%, Resets: November 10, 15:42
# 요금제 표시 이름은 /user?include=subscription 의 subscriptionTier에서 가져온다.
# 저장된 액세스 토큰은 갱신하지 않는다. 갱신은 grok이 auth.json을 바꿀 수 있다.

set -euo pipefail

DEFAULT_BASE_URL="https://cli-chat-proxy.grok.com/v1"
AUTH_FILE="${GROK_HOME:-$HOME/.grok}/auth.json"

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--summary] [--timeout SECONDS]

Print the complete Grok billing usage result as JSON.

options:
  -h, --help         show this help message and exit
  --summary          Print "Weekly limit (plan), N%, Resets: Month D, HH:MM".
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

base_url="${GROK_CLI_CHAT_PROXY_BASE_URL:-$DEFAULT_BASE_URL}"
base_url="${base_url%/}"
if ! [[ "$base_url" =~ ^https?://[^[:space:]]+$ ]]; then
  fail "GROK_CLI_CHAT_PROXY_BASE_URL must be an http or https URL."
fi
usage_url="$base_url/billing?format=credits"
user_url="$base_url/user?include=subscription"

# 로그인 항목이 여러 개면 만료가 가장 늦은 액세스 토큰을 쓴다. 토큰은 출력하지 않는다.
[[ -r "$AUTH_FILE" ]] || fail "Grok login was not found. Run 'grok login' first."

token=$(python3 -c '
import json
import sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(1)

records = []
if isinstance(data, dict) and isinstance(data.get("key"), str):
    records.append(data)
elif isinstance(data, dict):
    records.extend(value for value in data.values() if isinstance(value, dict))

chosen = None
for record in records:
    key = record.get("key")
    if not isinstance(key, str) or not key:
        continue
    expires = record.get("expires_at")
    expires = expires if isinstance(expires, str) else ""
    if chosen is None or expires > chosen[0]:
        chosen = (expires, key)

if chosen is None:
    sys.exit(1)
print(chosen[1])
' "$AUTH_FILE") || fail "Grok login does not contain an access token. Run 'grok login' again."

response_file=$(mktemp)
user_file=$(mktemp)
header_file=$(mktemp)
chmod 600 "$header_file"
trap 'rm -f "$response_file" "$user_file" "$header_file"' EXIT

# 토큰은 요청 헤더 파일로만 전달하고 인자 목록에 남기지 않는다.
printf 'Authorization: Bearer %s\n' "$token" > "$header_file"

# 응답 파일에 본문을 저장하고, 실패하면 메시지를 출력한 뒤 종료한다.
fetch() {
  local url=$1
  local outfile=$2
  local curl_status=0
  local http_code message detail

  http_code=$(curl -s --max-time "$timeout" -o "$outfile" -w '%{http_code}' \
    -H @"$header_file" \
    "$url") || curl_status=$?

  if [[ "$curl_status" -eq 28 ]]; then
    fail "Timed out waiting for Grok usage."
  fi
  if [[ "$curl_status" -ne 0 ]]; then
    fail "Could not reach $url (curl exit code $curl_status)."
  fi
  if [[ "$http_code" == "200" ]]; then
    return 0
  fi

  message=$(python3 -c '
import json
import sys

try:
    with open(sys.argv[1]) as f:
        error = json.load(f).get("error")
except Exception:
    sys.exit(0)
if isinstance(error, str):
    message = error.strip()
elif isinstance(error, dict):
    message = str(error.get("message") or "").strip()
else:
    message = ""
if message:
    print(message if message.endswith(".") else message + ".")
' "$outfile")
  detail="Grok returned HTTP $http_code."
  if [[ -n "$message" ]]; then
    detail="Grok returned HTTP $http_code: $message"
  fi
  if [[ "$http_code" == "401" ]]; then
    detail="$detail Run 'grok login' to refresh the login, then retry."
  fi
  fail "$detail"
}

fetch "$usage_url" "$response_file"
# 요약에만 요금제 이름이 필요하므로, JSON 출력일 때는 사용자 정보를 조회하지 않는다.
if [[ "$summary" == true ]]; then
  fetch "$user_url" "$user_file"
fi

if [[ "$summary" == true ]]; then
  python3 - "$response_file" "$user_file" <<'PY'
# 한 줄 형식: Weekly limit (X Premium+), 7%, Resets: November 10, 15:42
import json
import sys
from datetime import datetime

MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)
PERIOD_LABELS = {
    "USAGE_PERIOD_TYPE_WEEKLY": "Weekly limit",
    "USAGE_PERIOD_TYPE_MONTHLY": "Monthly limit",
}
# /user 의 subscriptionTier 코드와 Grok이 로그에 남기는 표시 이름.
TIER_LABELS = {
    "XPremiumPlus": "X Premium+",
    "XPremium": "X Premium",
    "XBasic": "X Basic",
    "SuperGrok": "SuperGrok",
    "SuperGrokPlus": "SuperGrok Plus",
    "SuperGrokHeavy": "SuperGrok Heavy",
    "SuperGrokLite": "SuperGrok Lite",
    "x_premium_plus": "X Premium+",
    "x_premium": "X Premium",
    "x_basic": "X Basic",
    "supergrok": "SuperGrok",
    "supergrok_plus": "SuperGrok Plus",
    "supergrok_heavy": "SuperGrok Heavy",
    "supergrok_lite": "SuperGrok Lite",
    "proxy-managed": "proxy-managed",
}


def format_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RuntimeError("Grok returned an invalid usage number.")
    if value != value or value in (float("inf"), float("-inf")):
        raise RuntimeError("Grok returned an invalid usage number.")
    return f"{value:.10f}".rstrip("0").rstrip(".")


def format_reset(value):
    # 현지 시간으로, 월 이름과 24시간제를 쓴다. 예: November 10, 15:42
    reset = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
    return f"{MONTHS[reset.month - 1]} {reset.day}, {reset.hour:02d}:{reset.minute:02d}"


def tier_label(raw):
    if not isinstance(raw, str) or not raw:
        raise RuntimeError("Grok did not return a subscription tier.")
    return TIER_LABELS.get(raw, raw)


def main():
    with open(sys.argv[1]) as f:
        data = json.load(f)
    with open(sys.argv[2]) as f:
        tier = tier_label(json.load(f).get("subscriptionTier"))
    config = data.get("config") if isinstance(data.get("config"), dict) else data
    if not isinstance(config, dict):
        raise RuntimeError("Grok returned an invalid usage response.")

    period = config.get("currentPeriod") if isinstance(config.get("currentPeriod"), dict) else {}
    label = PERIOD_LABELS.get(period.get("type"), "Usage limit")
    products = config.get("productUsage") if isinstance(config.get("productUsage"), list) else []
    used = config.get("creditUsagePercent")
    if used is None and len(products) == 1 and isinstance(products[0], dict):
        used = products[0].get("usagePercent")
    # 사용률이 0이면 creditUsagePercent와 productUsage가 응답에서 빠진다.
    # 기간이 있으면 0%이다. 상품이 둘 이상이면 어느 값인지 알 수 없어 실패한다.
    has_period = bool(period.get("end") or config.get("billingPeriodEnd"))
    if (
        used is None
        and has_period
        and (not products or (len(products) == 1 and isinstance(products[0], dict)))
    ):
        used = 0
    if used is None:
        raise RuntimeError("No usage limits were returned for the current Grok account.")
    reset_at = period.get("end") or config.get("billingPeriodEnd")
    if not isinstance(reset_at, str) or not reset_at:
        raise RuntimeError("Grok did not return a reset time.")
    print(f"{label} ({tier}), {format_number(used)}%, Resets: {format_reset(reset_at)}")


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
