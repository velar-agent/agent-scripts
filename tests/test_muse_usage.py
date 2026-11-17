"""Test Muse usage recovery with a stub CLI and no network calls.

대역 CLI로 뮤즈 사용량 복구를 검증하며 네트워크는 호출하지 않는다.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "muse-usage.sh"
RECOVERY_ARGS = [
    "exec", "--contributor-mode", "off",
    "--preset", "empty", "--max-model-steps", "1",
    "--disable-shell", "--disable-write", "--disable-web-tools",
    "--disable-reminders", "--disable-request-user-input",
    "--no-foreign-personal-context", "--no-session-log",
    "Compute 17 times 19. Reply with only the integer.",
]
NO_USAGE = {
    "reason": "server_sent_no_usage",
    "hint": "the server sent no usage data for this subscription",
    "allowance": None,
}
USAGE = {
    "allowance": {
        "tier": "Muse Code Everyday Usage",
        "window": {"usedPercent": 1.5, "resetsAtMs": 1805490000000},
        "weekly": {"usedPercent": 23.4, "resetsAtMs": 1805835600000},
    },
}


class MuseUsageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="muse-usage-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / "responses.json"
        self.log = self.root / "calls.jsonl"
        stub = self.root / "muse"
        stub.write_text(
            f"#!{sys.executable}\n" + r"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

config = json.loads(Path(os.environ["MUSE_TEST_CONFIG"]).read_text())
log = Path(os.environ["MUSE_TEST_LOG"])
calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
args = sys.argv[1:]
with log.open("a") as f:
    f.write(json.dumps(args) + "\n")

if args == ["usage", "--json"]:
    index = sum(call == args for call in calls)
    responses = config["usage"]
    response = responses[min(index, len(responses) - 1)]
    print(response["stdout"])
    if response.get("stderr"):
        print(response["stderr"], file=sys.stderr)
    sys.exit(response.get("exit_code", 0))
if args[:1] == ["exec"]:
    if sys.stdin.read():
        print("Unexpected input reached muse exec.", file=sys.stderr)
        sys.exit(99)
    print("Recovery prompt result: 323")
    print("Muse exec diagnostic.", file=sys.stderr)
    Path(os.environ["MUSE_TEST_PROMPT_PID"]).write_text(str(os.getpid()))
    if config.get("exec_child"):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        Path(os.environ["MUSE_TEST_CHILD_PID"]).write_text(str(child.pid))
    time.sleep(config.get("exec_delay", 0))
    sys.exit(config.get("exec_exit_code", 0))
print("Unexpected Muse command.", file=sys.stderr)
sys.exit(98)
""",
            encoding="utf-8",
        )
        stub.chmod(0o755)
        self.addCleanup(self.stop_stub_processes)

    def stop_stub_processes(self):
        path = self.root / "prompt.pid"
        if path.exists():
            try:
                os.killpg(int(path.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run_usage(self, responses, *args, exec_exit_code=0, exec_delay=0,
                  exec_child=False, recovery_timeout="5"):
        self.config.write_text(json.dumps({
            "usage": responses,
            "exec_exit_code": exec_exit_code,
            "exec_delay": exec_delay,
            "exec_child": exec_child,
        }), encoding="utf-8")
        self.log.unlink(missing_ok=True)
        env = os.environ.copy()
        env.update({
            "PATH": str(self.root) + os.pathsep + env.get("PATH", ""),
            "MUSE_TEST_CONFIG": str(self.config),
            "MUSE_TEST_LOG": str(self.log),
            "MUSE_TEST_PROMPT_PID": str(self.root / "prompt.pid"),
            "MUSE_TEST_CHILD_PID": str(self.root / "child.pid"),
            "MUSE_EXEC_TIMEOUT_SECONDS": recovery_timeout,
        })
        return subprocess.run(
            [str(SCRIPT), *args],
            env=env,
            input="Input for the caller must not reach muse exec.\n",
            capture_output=True,
            text=True,
            timeout=10,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    @staticmethod
    def response(data):
        return {"stdout": json.dumps(data)}

    def assert_usage(self, result, args):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        if args:
            self.assertEqual(json.loads(result.stdout), USAGE)
        else:
            self.assertIn("Subscription · Muse Code Everyday Usage", result.stdout)
            self.assertIn("23% used", result.stdout)
            self.assertNotIn("Recovery prompt result:", result.stdout)

    def test_existing_usage_does_not_run_prompt(self):
        for args in ((), ("--json",)):
            with self.subTest(args=args):
                result = self.run_usage([self.response(USAGE)], *args)
                self.assert_usage(result, args)
                self.assertEqual(self.calls(), [["usage", "--json"]])

    def test_missing_usage_runs_prompt_and_returns_fresh_usage(self):
        for args in ((), ("--json",)):
            with self.subTest(args=args):
                result = self.run_usage([self.response(NO_USAGE), self.response(USAGE)], *args)
                self.assert_usage(result, args)
                self.assertEqual(self.calls(), [["usage", "--json"], RECOVERY_ARGS, ["usage", "--json"]])

    def test_other_responses_do_not_run_prompt(self):
        for response in (
            self.response({"reason": "not_subscribed", "allowance": None}),
            self.response({"allowance": None}),
            {"stdout": "invalid JSON"},
        ):
            with self.subTest(response=response):
                result = self.run_usage([response])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.calls(), [["usage", "--json"]])

    def test_failed_initial_query_does_not_run_prompt(self):
        result = self.run_usage([{
            "stdout": json.dumps(NO_USAGE), "stderr": "Usage request failed.", "exit_code": 7,
        }])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Usage request failed.", result.stderr)
        self.assertIn("muse exit code 7", result.stderr)
        self.assertEqual(self.calls(), [["usage", "--json"]])

    def test_failed_prompt_reports_error_without_another_query(self):
        result = self.run_usage([self.response(NO_USAGE)], exec_exit_code=9)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Muse exec diagnostic.", result.stderr)
        self.assertIn("Could not start Muse usage with a recovery request (muse exit code 9)", result.stderr)
        self.assertEqual(self.calls(), [["usage", "--json"], RECOVERY_ARGS])

    def test_missing_usage_after_retry_does_not_run_prompt_again(self):
        for args in ((), ("--json",)):
            with self.subTest(args=args):
                result = self.run_usage([self.response(NO_USAGE)], *args)
                if args:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), NO_USAGE)
                else:
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Error: server_sent_no_usage", result.stderr)
                self.assertEqual(self.calls(), [["usage", "--json"], RECOVERY_ARGS, ["usage", "--json"]])

    def test_failed_retry_reports_query_error(self):
        result = self.run_usage([
            self.response(NO_USAGE),
            {"stdout": "", "stderr": "Retry request failed.", "exit_code": 8},
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Retry request failed.", result.stderr)
        self.assertIn("muse exit code 8", result.stderr)
        self.assertEqual(self.calls(), [["usage", "--json"], RECOVERY_ARGS, ["usage", "--json"]])

    def test_prompt_timeout_stops_its_process_group_without_retry(self):
        result = self.run_usage(
            [self.response(NO_USAGE)],
            exec_delay=30,
            exec_child=True,
            recovery_timeout="0.5",
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Timed out waiting for Muse recovery request after 0.5 seconds", result.stderr)
        self.assertEqual(self.calls(), [["usage", "--json"], RECOVERY_ARGS])
        for name in ("prompt.pid", "child.pid"):
            pid = int((self.root / name).read_text())
            # A terminated orphan may briefly remain as a zombie before init reaps it.
            # 종료된 고아 프로세스는 init이 수거하기 전 잠시 좀비로 남을 수 있다.
            probe = subprocess.run(
                ["ps", "-o", "stat=", "-p", str(pid)],
                capture_output=True, text=True, timeout=5,
            )
            self.assertIn(probe.returncode, (0, 1), probe.stderr)
            self.assertEqual(probe.stderr, "")
            state = probe.stdout.strip()
            self.assertTrue(not state or state.startswith("Z"), f"Process {pid} is still running: {state}")

    def test_invalid_recovery_timeout_does_not_start_prompt(self):
        for timeout in ("0", "-1", "nan", "inf", "invalid"):
            with self.subTest(timeout=timeout):
                result = self.run_usage([self.response(NO_USAGE)], recovery_timeout=timeout)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("MUSE_EXEC_TIMEOUT_SECONDS must be a positive, finite number", result.stderr)
                self.assertEqual(self.calls(), [["usage", "--json"]])


if __name__ == "__main__":
    unittest.main()
