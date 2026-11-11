#!/usr/bin/env bash
# 코덱스, 그로크, 클로드, 제미나의 주간 한도를 소진계획 한 목록으로 출력한다.
# 사용률 칸은 12칸이다. 부족한 왼쪽은 밑줄로 채우고, 본문 앞에는 공백을 둔다.
# 예: `_______ 50%u`, `_ 36%u, 59%u`
# 초기화 시각은 분이 1분 이상이면 다음 정시로 올리고, 0–11시는 오전, 12–18시는 오후, 19–23시는 저녁이다.
# 예: 2:02 AM → 오전3시, 15:42 → 오후4시, 8:00 PM → 저녁8시

set -euo pipefail

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--timeout SECONDS]

Print today's date and the weekly burn plan for Codex, Grok, Claude, and Gemini.

options:
  -h, --help         show this help message and exit
  --timeout SECONDS  Maximum time to wait for each source (default: 20).
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

timeout=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
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

# curl --max-time 형식에 맞는 양의 유한한 수만 허용한다. 각 조회에 그대로 넘긴다.
if ! [[ "$timeout" =~ ^[0-9]*\.?[0-9]+$ ]] || ! awk -v t="$timeout" 'BEGIN { exit !(t > 0) }'; then
  fail "--timeout must be a positive, finite number"
fi

command -v python3 >/dev/null 2>&1 || fail "python3 was not found in PATH."

script_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 네 조회는 서로 기다리지 않는다. 실패하면 쪽의 오류를 그대로 보여 주고 끝낸다.
"$script_dir/codex-account-rateLimits-read.py" --weekly-limit --timeout "$timeout" \
  >"$work/codex" 2>"$work/codex.err" &
codex_pid=$!
"$script_dir/grok-billing.sh" --summary --timeout "$timeout" \
  >"$work/grok" 2>"$work/grok.err" &
grok_pid=$!
"$script_dir/claude-usage.sh" --summary --timeout "$timeout" \
  >"$work/claude" 2>"$work/claude.err" &
claude_pid=$!
"$script_dir/agy-print-usage.sh" \
  >"$work/gemini" 2>"$work/gemini.err" &
gemini_pid=$!

codex_ec=0
grok_ec=0
claude_ec=0
gemini_ec=0
wait "$codex_pid" || codex_ec=$?
wait "$grok_pid" || grok_ec=$?
wait "$claude_pid" || claude_ec=$?
wait "$gemini_pid" || gemini_ec=$?

if [[ "$codex_ec" -ne 0 || "$grok_ec" -ne 0 || "$claude_ec" -ne 0 || "$gemini_ec" -ne 0 ]]; then
  cat "$work/codex.err" "$work/grok.err" "$work/claude.err" "$work/gemini.err" >&2
  exit 1
fi

python3 - "$work/codex" "$work/grok" "$work/claude" "$work/gemini" <<'PY'
import re
import sys
from datetime import datetime, timedelta

WEEKDAYS = "월화수목금토일"
SHORT_MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}
LONG_MONTHS = {
    "January": 1, "February": 2, "March": 3, "April": 4, "May": 5, "June": 6,
    "July": 7, "August": 8, "September": 9, "October": 10, "November": 11, "December": 12,
}
CODEX_RE = re.compile(
    r"^Weekly limit: (?P<left>\d+)% left"
    r"(?: \((?P<reset>resets (?P<hour>\d{1,2}):(?P<minute>\d{2}) "
    r"(?P<ampm>AM|PM) on (?P<day>\d{1,2}) (?P<month>[A-Z][a-z]{2}))\))?$"
)
GROK_RE = re.compile(
    r", (?P<pct>\d+(?:\.\d+)?)%, "
    r"(?P<reset>Resets: (?P<month>[A-Z][a-z]+) (?P<day>\d{1,2}), "
    r"(?P<hour>\d{2}):(?P<minute>\d{2}))$"
)
CLAUDE_RESET_RE = re.compile(
    r"Resets (?P<month>[A-Z][a-z]{2}) (?P<day>\d{1,2})(?:, (?P<year>\d{4}))? at "
    r"(?P<hour>\d{1,2})(?::(?P<minute>\d{2}))?(?P<ampm>am|pm) \([^)]*\)"
)
GEMINI_ARGON_RE = re.compile(
    r"^Gemini 4 Argon\s+Gemini 4 Argon Weekly Limit\s+(?P<left>\d+)%\s+"
    r"(?:(?P<iso>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)|"
    r"(?P<reset>(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2}) "
    r"(?P<hour>\d{2}):(?P<minute>\d{2}) \S+))$",
    re.MULTILINE,
)


def read_text(path):
    with open(path) as handle:
        return handle.read().strip()


def local_now():
    # 요약 문구의 시각은 이미 이 기계의 현지 벽시각이다.
    return datetime.now().astimezone().replace(tzinfo=None)


def wall_clock(year, month, day, hour, minute, now):
    if year is None:
        candidate = datetime(now.year, month, day, hour, minute)
        # 연말이면 내년 1월처럼, 올해로 읽으면 이미 지난 날짜가 된다.
        if candidate < now - timedelta(days=2):
            candidate = datetime(now.year + 1, month, day, hour, minute)
        return candidate
    return datetime(year, month, day, hour, minute)


def clock_24(hour, minute, ampm):
    hour = int(hour)
    minute = int(minute)
    if ampm is None:
        return hour, minute
    marker = ampm.lower()
    if marker == "pm" and hour != 12:
        hour += 12
    if marker == "am" and hour == 12:
        hour = 0
    return hour, minute


def format_korean_date(moment):
    return f"{moment.month}월{moment.day:02d}일({WEEKDAYS[moment.weekday()]})"


def format_korean_reset(moment):
    # 정시가 아니면 다음 정시로 올린다. 2:02는 오전3시, 15:42는 오후4시다.
    rounded = moment.replace(second=0, microsecond=0)
    if rounded.minute:
        rounded = rounded.replace(minute=0) + timedelta(hours=1)
    hour = rounded.hour
    if hour < 12:
        period = "오전"
        clock = 12 if hour == 0 else hour
    elif hour < 19:
        period = "오후"
        clock = 12 if hour == 12 else hour - 12
    else:
        period = "저녁"
        clock = hour - 12
    return f"{format_korean_date(rounded)}_{period}{clock}시"


def format_korean_resets(moments):
    texts = []
    for moment in moments:
        text = format_korean_reset(moment)
        if text not in texts:
            texts.append(text)
    if not texts:
        raise RuntimeError("A reset time is missing.")
    return ", ".join(texts)


def usage_field(numbers):
    # `_______ 50%u`와 `_ 36%u, 59%u`가 모두 12칸이 되도록 왼쪽에 밑줄을 둔다.
    text = ", ".join(f"{number}%u" for number in numbers)
    if len(text) >= 12:
        return text
    return f"{'_' * (11 - len(text))} {text}"


def parse_codex(text, now):
    match = CODEX_RE.match(text)
    if match is None:
        raise RuntimeError(f"Could not parse the Codex summary: {text!r}")
    if match.group("reset") is None:
        raise RuntimeError("Codex did not return a reset time.")
    month = SHORT_MONTHS.get(match.group("month"))
    if month is None:
        raise RuntimeError(f"Could not parse the Codex summary: {text!r}")
    hour, minute = clock_24(match.group("hour"), match.group("minute"), match.group("ampm"))
    moment = wall_clock(None, month, int(match.group("day")), hour, minute, now)
    # 코덱스 요약은 남은 비율이다. 그로크·클로드와 같이 사용한 비율로 적는다.
    used = 100 - int(match.group("left"))
    return [str(used)], match.group("reset"), [moment]


def parse_grok(text, now):
    match = GROK_RE.search(text)
    if match is None:
        raise RuntimeError(f"Could not parse the Grok summary: {text!r}")
    month = LONG_MONTHS.get(match.group("month"))
    if month is None:
        raise RuntimeError(f"Could not parse the Grok summary: {text!r}")
    moment = wall_clock(
        None, month, int(match.group("day")), int(match.group("hour")), int(match.group("minute")), now
    )
    return [match.group("pct")], match.group("reset"), [moment]


def parse_claude(text, now):
    # 세션 한도는 빠진다. 목록의 시각은 주간 초기화이고, 사용률도 그 블록의 순서대로 적는다.
    lines = text.splitlines()
    body = None
    for index, line in enumerate(lines):
        if line.startswith("Current week"):
            if index + 1 < len(lines):
                body = lines[index + 1].strip()
            break
    if not body:
        raise RuntimeError("No weekly limit was returned for the current Claude account.")
    numbers = re.findall(r"(\d+)% used", body.split("Resets ", 1)[0])
    resets = list(CLAUDE_RESET_RE.finditer(body))
    if not numbers or not resets:
        raise RuntimeError(f"Could not parse the Claude summary: {body!r}")
    moments = []
    for reset in resets:
        month = SHORT_MONTHS.get(reset.group("month"))
        if month is None:
            raise RuntimeError(f"Could not parse the Claude summary: {body!r}")
        minute = reset.group("minute") or "0"
        hour, minute = clock_24(reset.group("hour"), minute, reset.group("ampm"))
        year = int(reset.group("year")) if reset.group("year") else None
        moments.append(wall_clock(year, month, int(reset.group("day")), hour, minute, now))
    reset_text = body[body.find("Resets "):]
    return numbers, reset_text, moments


def parse_gemini(text, now):
    match = GEMINI_ARGON_RE.search(text)
    if match is None:
        raise RuntimeError(f"Could not parse the Gemini 4 Argon summary: {text!r}")
    if match.group("iso") is not None:
        local_dt = datetime.fromisoformat(match.group("iso").replace("Z", "+00:00")).astimezone()
        reset_text = f"resets {local_dt.strftime('%Y-%m-%d %H:%M %Z')}"
        moment = local_dt.replace(tzinfo=None, second=0, microsecond=0)
    else:
        reset_text = f"resets {match.group('reset')}"
        moment = wall_clock(
            int(match.group("year")),
            int(match.group("month")),
            int(match.group("day")),
            int(match.group("hour")),
            int(match.group("minute")),
            now,
        )
    # Gemini 4 Argon 요약은 남은 비율이다. 그로크·클로드와 같이 사용한 비율로 적는다.
    used = 100 - int(match.group("left"))
    return [str(used)], reset_text, [moment]


def render(now, entries):
    lines = [f"-   오늘 `{format_korean_date(now)}`"]
    # 초기화 시각이 여러 개면 가장 먼 시각을 기준으로 내림차순 정렬한다.
    entries = sorted(entries, key=lambda entry: max(entry[3]), reverse=True)
    for name, numbers, reset_text, moments in entries:
        lines.append("")
        lines.append(
            f"-   {name} (소진계획: `{usage_field(numbers)}`, "
            f"`{format_korean_resets(moments)}`, `{reset_text}`)"
        )
    return "\n".join(lines)


def main():
    now = local_now()
    codex, grok, claude, gemini = (read_text(path) for path in sys.argv[1:])
    entries = [
        ("코덱스",) + parse_codex(codex, now),
        ("그로크",) + parse_grok(grok, now),
        ("클로드",) + parse_claude(claude, now),
        ("제미나",) + parse_gemini(gemini, now),
    ]
    print(render(now, entries))


try:
    main()
except (OSError, RuntimeError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
