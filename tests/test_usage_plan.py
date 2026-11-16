"""Tests for usage-plan.sh with stub sources; no network or real CLIs.

usage-plan.sh를 대역 조회 스크립트로 확인한다. 네트워크와 실제 CLI는 부르지 않는다.
"""

import re
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "usage-plan.sh"
WEEKDAYS = "월화수목금토일"
SHORT_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
LONG_MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)
# Reset offsets in days with the hour and minute; distinct days fix the expected order.
# 초기화 시각의 일수 차이와 시·분이다. 날짜가 모두 달라 기대 순서가 정해진다.
RESETS = {
    "codex": (6, 2, 6),
    "gemini": (5, 13, 55),
    "muse": (4, 9, 0),
    "grokbot": (3, 2, 49),
    "claude": (2, 19, 0),
    "grok": (1, 15, 42),
}
EXPECTED_ORDER = ["코덱스", "제미나", "뮤으즈", "그록봇", "클로드", "그로크"]


def clock_12(moment):
    # Codex and Muse print times like "2:06 AM".
    # 코덱스와 뮤즈는 "2:06 AM"처럼 시각을 찍는다.
    hour = moment.hour % 12 or 12
    return f"{hour}:{moment.minute:02d} {'AM' if moment.hour < 12 else 'PM'}"


def korean_date(moment):
    # Same text as usage-plan.sh: unpadded month, zero-padded day, weekday in parentheses.
    # usage-plan.sh와 같은 표기다. 월은 그대로, 일은 두 자리, 괄호 안에 요일을 적는다.
    return f"{moment.month}월{moment.day:02d}일({WEEKDAYS[moment.weekday()]})"


def grok_style(moment):
    # Grok and Grok Bot print reset times like "November 18, 02:49".
    # 그로크와 그록봇은 "November 18, 02:49"처럼 초기화 시각을 찍는다.
    return f"{LONG_MONTHS[moment.month - 1]} {moment.day}, {moment.hour:02d}:{moment.minute:02d}"


class UsagePlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="usage-plan-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Link the real script so it runs the stub sources placed beside the link.
        # 실제 스크립트를 링크해, 링크 옆에 둔 대역 조회를 실행하게 한다.
        (self.root / "usage-plan.sh").symlink_to(SCRIPT)
        base = datetime.now().replace(second=0, microsecond=0)
        self.resets = {
            name: (base + timedelta(days=days)).replace(hour=hour, minute=minute)
            for name, (days, hour, minute) in RESETS.items()
        }
        self.write_default_sources()

    def write_source(self, name, stdout="", exit_code=0, stderr=""):
        lines = ["#!/bin/sh"]
        if stdout:
            lines += ["cat <<'EOF'", stdout, "EOF"]
        if stderr:
            lines += ["cat <<'EOF' >&2", stderr, "EOF"]
        lines.append(f"exit {exit_code}")
        path = self.root / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        path.chmod(0o755)

    def write_default_sources(self):
        r = self.resets
        self.write_source(
            "codex-account-rateLimits-read.py",
            f"Weekly limit: 48% left (resets {clock_12(r['codex'])} on {r['codex'].day} "
            f"{SHORT_MONTHS[r['codex'].month - 1]})",
        )
        self.write_source(
            "grok-billing.sh",
            f"Weekly limit (X Premium+), 23%, Resets: {grok_style(r['grok'])}",
        )
        self.write_source(
            "claude-usage.sh",
            "Current week (all models) :\n"
            f"  20% used, Resets {SHORT_MONTHS[r['claude'].month - 1]} {r['claude'].day} at 7pm (Asia/Seoul)",
        )
        self.write_source(
            "agy-print-usage.sh",
            f"Gemini 4 Argon    Gemini 4 Argon Weekly Limit    91%    {r['gemini']:%Y-%m-%d %H:%M} KST",
        )
        self.write_source(
            "muse-usage.sh",
            "Subscription · Muse Code Everyday Usage\n"
            f"  Weekly         23% used · Resets {SHORT_MONTHS[r['muse'].month - 1]} {r['muse'].day} "
            f"at {clock_12(r['muse'])}",
        )
        self.write_grok_bot(f"Weekly limit (X Premium+), 74.89%, Resets: {grok_style(r['grokbot'])}")

    def write_grok_bot(self, summary):
        self.write_source("grok-bot-cursor-usage.sh", summary)

    def run_plan(self):
        return subprocess.run(
            [str(self.root / "usage-plan.sh"), "--timeout", "5"],
            capture_output=True,
            text=True,
            timeout=60,
        )

    def entries(self, stdout):
        return [line for line in stdout.splitlines() if "(소진계획: " in line]

    def test_grok_bot_row_drops_fraction_and_keeps_order(self):
        result = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = self.entries(result.stdout)
        names = [re.match(r"^-   (\S+) ", line).group(1) for line in entries]
        self.assertEqual(names, EXPECTED_ORDER)
        reset = self.resets["grokbot"]
        self.assertIn(
            f"-   그록봇 (소진계획: `_______ 74%u`, `{korean_date(reset)}_오전2시`, "
            f"`Resets: {grok_style(reset)}`)",
            entries,
        )

    def test_grok_bot_zero_percent_keeps_width(self):
        self.write_grok_bot(f"Weekly limit (X Premium+), 0%, Resets: {grok_style(self.resets['grokbot'])}")
        result = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        row = next(line for line in self.entries(result.stdout) if line.startswith("-   그록봇 "))
        self.assertIn("`________ 0%u`", row)

    def test_grok_bot_trial_or_unknown_reset_fails_plan(self):
        # The note shows reset times, so a trial expiry or a missing reset is an error.
        # 노트는 초기화 시각을 보여 주므로, 체험 만료나 빠진 초기화 시각은 오류다.
        summaries = (
            f"Trial limit (X Premium+), 12.5%, Expires: {grok_style(self.resets['grokbot'])}",
            "Weekly limit (X Premium+), 74.89%, Resets: unknown",
        )
        for summary in summaries:
            with self.subTest(summary=summary):
                self.write_grok_bot(summary)
                result = self.run_plan()
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("Could not parse the Grok Bot summary", result.stderr)

    def test_grok_bot_failure_fails_plan_with_its_error(self):
        message = "Error: Grok Bot returned HTTP 401. Replace GROK_BOT_ACCESS_TOKEN with a fresh access token."
        self.write_source("grok-bot-cursor-usage.sh", exit_code=1, stderr=message)
        result = self.run_plan()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
