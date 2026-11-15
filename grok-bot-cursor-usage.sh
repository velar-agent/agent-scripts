#!/usr/bin/env bash
# Query Grok Bot usage with a Cursor access token from .env or the environment.
# .env 또는 환경변수의 Cursor 액세스 토큰으로 Grok Bot 사용량을 조회한다.
# An environment token takes precedence over the env file and makes .env optional.
# 환경변수의 토큰을 env 파일보다 우선하며, 환경변수만 설정하면 .env는 없어도 된다.
# Print JSON by default; --summary prints the usage percentage and reset time.
# 기본 출력은 JSON이며, --summary는 사용률과 초기화 시각을 출력한다.

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 was not found in PATH." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$script_dir" "$@" <<'PY'
import argparse
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Use the desktop app's internal Connect-RPC endpoint.
# 데스크톱 앱의 내부 Connect-RPC 엔드포인트를 사용한다.
USAGE_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
TOKEN_ENV = "GROK_BOT_ACCESS_TOKEN"
REQUEST_TIMEOUT = 20
MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)


def read_token(env_file):
    # Parse only the token assignment; never execute or expand .env contents.
    # 토큰 대입문만 파싱하며 .env 내용을 실행하거나 변수 확장하지 않는다.
    token = os.environ.get(TOKEN_ENV)
    if token is None:
        try:
            lines = env_file.read_text(encoding="utf-8-sig").splitlines()
        except FileNotFoundError:
            lines = []
        except (OSError, UnicodeError):
            raise RuntimeError(f"Could not read env file: {env_file}") from None
        for line_number, line in enumerate(lines, start=1):
            match = re.match(r"^\s*(?:export\s+)?" + TOKEN_ENV + r"\s*=(.*)$", line)
            if match is None:
                continue
            try:
                values = shlex.split(match.group(1), comments=True, posix=True)
            except ValueError:
                raise RuntimeError(
                    f"Invalid {TOKEN_ENV} assignment in {env_file} at line {line_number}."
                ) from None
            if len(values) > 1:
                raise RuntimeError(
                    f"Invalid {TOKEN_ENV} assignment in {env_file} at line {line_number}."
                )
            token = values[0] if values else ""
    if token is None or not token.strip():
        raise RuntimeError(f"Set {TOKEN_ENV} in the environment or in {env_file}.")
    token = token.strip()
    if re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", token) is None:
        raise RuntimeError(f"{TOKEN_ENV} must contain only the access token, without 'Bearer '.")
    return token


def fetch_usage(token):
    curl = shutil.which("curl")
    if curl is None:
        raise RuntimeError("curl was not found in PATH.")
    # Pass the token through stdin, avoiding command arguments and temporary files.
    # 토큰을 표준 입력으로 전달해 명령 인자와 임시 파일에 남기지 않는다.
    environment = os.environ.copy()
    environment.pop(TOKEN_ENV, None)
    try:
        result = subprocess.run(
            [
                curl, "--disable", "--silent", "--max-time", str(REQUEST_TIMEOUT),
                "--request", "POST", "--header", "@-",
                "--header", "Content-Type: application/json",
                "--header", "Connect-Protocol-Version: 1",
                "--data", "{}", "--write-out", "\n%{http_code}", USAGE_URL,
            ],
            input=f"Authorization: Bearer {token}\n",
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=environment,
            timeout=REQUEST_TIMEOUT + 5,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Timed out waiting for Grok Bot usage.") from None
    if result.returncode == 28:
        raise RuntimeError("Timed out waiting for Grok Bot usage.")
    if result.returncode != 0:
        raise RuntimeError(f"Could not reach Grok Bot (curl exit code {result.returncode}).")
    body, separator, status = result.stdout.rpartition("\n")
    if not separator or not re.fullmatch(r"\d{3}", status):
        raise RuntimeError("curl did not return a valid HTTP status.")
    if status == "401":
        raise RuntimeError(f"Grok Bot returned HTTP 401. Replace {TOKEN_ENV} with a fresh access token.")
    if status == "403":
        raise RuntimeError("Grok Bot returned HTTP 403. Check the account's access to Grok Bot.")
    if status == "429":
        raise RuntimeError("Grok Bot returned HTTP 429. Wait before retrying.")
    if status != "200":
        raise RuntimeError(f"Grok Bot returned HTTP {status}.")
    try:
        data = json.loads(body)
        json.dumps(data, allow_nan=False)
    except ValueError:
        raise RuntimeError("Grok Bot returned invalid JSON.") from None
    if not isinstance(data, dict):
        raise RuntimeError("Grok Bot returned an invalid usage response.")
    return data


def parse_timestamp(value):
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if moment.tzinfo is None:
            raise ValueError
        return moment
    except (AttributeError, TypeError, ValueError):
        raise RuntimeError("Grok Bot returned an invalid usage timestamp.") from None


def format_timestamp(value):
    if value is None:
        return "unknown"
    moment = parse_timestamp(value).astimezone()
    return f"{MONTHS[moment.month - 1]} {moment.day}, {moment.hour:02d}:{moment.minute:02d}"


def print_summary(data):
    if data.get("usesPooledEnterpriseAllowance"):
        raise RuntimeError("This account uses a pooled enterprise allowance. Run without --summary for details.")
    used = data.get("usagePercent")
    # A missing percentage is unavailable, not zero; trial usage can have no included limit.
    # 사용률 누락은 0%가 아닌 조회 불가이며, 체험 사용량은 기본 한도가 없어도 표시한다.
    if used is None:
        raise RuntimeError("No usage percentage was returned for the current Grok Bot account.")
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or used < 0:
        raise RuntimeError("Grok Bot returned an invalid usage percentage.")
    label = "Weekly limit"
    reset_label = "Resets"
    reset = data.get("nextResetTimestampUtc")
    trial_end = data.get("sandTrialExpiresAt")
    if trial_end is not None and parse_timestamp(trial_end) > datetime.now(timezone.utc):
        label, reset_label, reset = "Trial limit", "Expires", trial_end
    plan = next(
        (value.strip() for value in (
            data.get("grokPlanLabel"), data.get("includedUsageSuperGrokPlan"), data.get("cursorPlanName"),
        ) if isinstance(value, str) and value.strip()),
        None,
    )
    if plan:
        label += f" ({' '.join(plan.split())})"
    percent = f"{used:.2f}".rstrip("0").rstrip(".")
    print(f"{label}, {percent}%, {reset_label}: {format_timestamp(reset)}")


def main():
    default_env_file = Path(sys.argv[1]) / ".env"
    parser = argparse.ArgumentParser(
        prog="grok-bot-cursor-usage.sh",
        description="Print the complete Grok Bot usage result as JSON.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Authentication:\n"
            f"  Set {TOKEN_ENV} in the environment or in the env file.\n"
            "  With an environment token, .env is optional.\n"
            "  The environment takes precedence over .env and --env-file.\n"
            "  Exported values remain in the current shell until unset or the shell exits.\n"
            "  Tokens are not refreshed automatically.\n\n"
            "Example without .env (run from the script directory):\n"
            f'  export {TOKEN_ENV}="$(./grok-bot-cursor-token-from-macos-keychain.sh)"\n'
            "  ./grok-bot-cursor-usage.sh --summary\n\n"
            "On Linux, use grok-bot-cursor-token-from-linux.sh to extract the token.\n"
            f"Use 'unset {TOKEN_ENV}' to return to env-file authentication.\n"
            "Requires python3 and curl."
        ),
    )
    parser.add_argument("--summary", action="store_true", help="print the usage percentage and reset time on one line")
    parser.add_argument("--env-file", type=Path, default=default_env_file, metavar="PATH", help="token file (default: .env next to this script)")
    args = parser.parse_args(sys.argv[2:])
    data = fetch_usage(read_token(args.env_file))
    if args.summary:
        print_summary(data)
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False))


try:
    main()
except (OSError, RuntimeError, ValueError, OverflowError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
