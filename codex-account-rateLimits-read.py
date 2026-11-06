#!/usr/bin/env python3
"""Codex CLI 로그인 정보로 계정 한도를 조회하고 선택적으로 주간 요약을 출력한다."""

import argparse
from datetime import datetime, timezone
import json
import queue
import subprocess
import sys
import threading
import time


def read_rate_limits(timeout):
    with subprocess.Popen(
        ["codex", "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
    ) as process:
        messages = queue.Queue()
        deadline = time.monotonic() + timeout

        # 별도 스레드에서 읽어 줄바꿈이 오지 않아도 조회 시간 제한을 지킨다.
        def receive():
            try:
                for line in process.stdout:
                    messages.put(line)
            finally:
                messages.put(None)

        reader = threading.Thread(target=receive, daemon=True)
        reader.start()

        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def request(request_id, method, params):
            send({"id": request_id, "method": method, "params": params})
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("Timed out waiting for Codex rate limits.")
                try:
                    line = messages.get(timeout=remaining)
                except queue.Empty:
                    raise RuntimeError("Timed out waiting for Codex rate limits.") from None
                if line is None:
                    raise RuntimeError("Codex app server exited before replying.")
                message = json.loads(line)
                # 초기화 알림 등 요청과 무관한 메시지는 건너뛴다.
                if message.get("id") != request_id:
                    continue
                if "error" in message:
                    raise RuntimeError(message["error"]["message"])
                if not isinstance(message.get("result"), dict):
                    raise RuntimeError("Codex returned an invalid response.")
                return message["result"]

        try:
            request(
                1,
                "initialize",
                {"clientInfo": {"name": "codex_weekly_limit", "version": "1.0.0"}},
            )
            send({"method": "initialized"})
            return request(
                2, "account/rateLimits/read", {"excludeResetCreditDetails": True}
            )
        finally:
            # 조회 성공 여부와 관계없이 이 스크립트가 실행한 서버를 정리한다.
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            reader.join(timeout=1)


def format_weekly_limit(result):
    buckets = result.get("rateLimitsByLimitId") or {}
    snapshot = buckets.get("codex") or result.get("rateLimits") or {}

    # 요금제에 따라 주간 한도가 primary 또는 secondary에 들어온다.
    for name in ("primary", "secondary"):
        window = snapshot.get(name)
        if not window or window.get("windowDurationMins") != 7 * 24 * 60:
            continue
        used = window.get("usedPercent")
        if type(used) is not int:
            raise RuntimeError("Codex returned an invalid weekly usage percentage.")
        remaining = max(0, min(100, 100 - used))
        output = f"Weekly limit: {remaining}% left"
        if window.get("resetsAt") is not None:
            reset = datetime.fromtimestamp(window["resetsAt"], timezone.utc).astimezone()
            # 로캘과 관계없이 영문 월 이름과 12시간제로 표시한다.
            month = (
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            )[reset.month - 1]
            period = "AM" if reset.hour < 12 else "PM"
            output += (
                f" (resets {reset.hour % 12 or 12}:{reset.minute:02d} {period}"
                f" on {reset.day} {month})"
            )
        return output

    raise RuntimeError("No weekly limit was returned for the current Codex account.")


def main():
    parser = argparse.ArgumentParser(
        description="Print the complete Codex account/rateLimits/read result as JSON."
    )
    parser.add_argument(
        "--weekly-limit", action="store_true",
        help="Print the weekly limit summary.",
    )
    parser.add_argument(
        "--timeout", type=float, default=20, metavar="SECONDS",
        help="Maximum time to wait for a response (default: 20).",
    )
    args = parser.parse_args()
    if not 0 < args.timeout < float("inf"):
        parser.error("--timeout must be a positive, finite number")
    try:
        result = read_rate_limits(args.timeout)
        if args.weekly_limit:
            print(format_weekly_limit(result))
        else:
            print(json.dumps(result, ensure_ascii=False, indent=2))
    except FileNotFoundError:
        print("Error: codex was not found in PATH.", file=sys.stderr)
        return 1
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
