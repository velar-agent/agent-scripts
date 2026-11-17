#!/usr/bin/env bash
# Query Muse subscription usage through its CLI, without reading or printing tokens.
# muse CLI로 구독 사용량(5시간 창·주간 한도)을 조회하며 토큰을 직접 읽거나 출력하지 않는다.
# Print a short summary by default, or JSON with --json.
# 기본 출력은 짧은 텍스트 요약이고, --json 옵션 사용 시 JSON 형식으로 출력한다.

set -euo pipefail

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--json]

Print the Muse subscription usage summary as text.
If the server returns server_sent_no_usage, send one short model request
with contributor mode off (for this run only), then retry usage once.

options:
  -h, --help         show this help message and exit
  --json             Print the complete usage result as JSON.

environment:
  MUSE_EXEC_TIMEOUT_SECONDS  Recovery request time limit (default: 60 seconds).
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
response_file="$work/usage.json"

fetch_usage() {
  local muse_status=0
  muse usage --json > "$response_file" || muse_status=$?
  if [[ "$muse_status" -ne 0 ]]; then
    fail "Could not get Muse usage (muse exit code $muse_status)."
  fi
}

fetch_usage

# Open a usage window only for this server response, then query once more.
# 이 서버 응답일 때만 사용 구간을 열고 한 번 더 조회한다.
if python3 - "$response_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(1)

missing_usage = (
    isinstance(data, dict)
    and not isinstance(data.get("allowance"), dict)
    and data.get("reason") == "server_sent_no_usage"
)
sys.exit(0 if missing_usage else 1)
PY
then
  # Keep the recovery reply and CLI diagnostics out of the summary and JSON output.
  # 복구 응답과 CLI 진단 메시지가 요약 및 JSON 출력에 섞이지 않게 한다.
  if ! python3 - >"$work/exec.log" 2>&1 <<'PY'
import math
import os
import signal
import subprocess
import sys


def interrupted(signum, frame):
    raise SystemExit(128 + signum)


def run_prompt():
    try:
        timeout = float(os.environ.get("MUSE_EXEC_TIMEOUT_SECONDS", "60"))
    except ValueError:
        timeout = 0
    if not math.isfinite(timeout) or timeout <= 0:
        raise RuntimeError("MUSE_EXEC_TIMEOUT_SECONDS must be a positive, finite number.")

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)

    process = None
    try:
        # Greetings can finish without a model call. Make a real subscription request,
        # disabling contributor mode only for recovery, with tools and session logs off.
        # 인사는 모델 호출 없이 끝날 수 있다. 복구 요청에만 기여 모드를 끄고 실제
        # 구독 요청을 보내며, 도구 실행과 세션 기록을 끈다.
        process = subprocess.Popen(
            [
                "muse", "exec", "--contributor-mode", "off",
                "--preset", "empty", "--max-model-steps", "1",
                "--disable-shell", "--disable-write", "--disable-web-tools",
                "--disable-reminders", "--disable-request-user-input",
                "--no-foreign-personal-context", "--no-session-log",
                "Compute 17 times 19. Reply with only the integer.",
            ],
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Timed out waiting for Muse recovery request after {timeout:g} seconds.") from None
        if status != 0:
            raise RuntimeError(f"Could not start Muse usage with a recovery request (muse exit code {status}).")
    except BaseException:
        # Stop the entire recovery process group, including any tool subprocesses.
        # 도구 하위 프로세스를 포함해 복구용 프로세스 그룹 전체를 종료한다.
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise


try:
    run_prompt()
except (OSError, RuntimeError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
  then
    cat "$work/exec.log" >&2
    exit 1
  fi
  fetch_usage
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
