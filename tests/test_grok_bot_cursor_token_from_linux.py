import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "grok-bot-cursor-token-from-linux.sh"
TOKEN = "test.token_123-abc"
PASSWORD = "zxqfb"
# Fixed OpenSSL ciphertexts using Chromium's published Linux key derivation vectors.
# Chromium이 공개한 Linux 키 유도 검증값으로 OpenSSL에서 만든 고정 암호문이다.
V10 = bytes.fromhex("e13539552c89c7ff37ef857e62402b30500703219bc949acba914aa5ca0b57ac")
V11 = bytes.fromhex("d3e221b0d4fa17be6140c679adb3c16ba0a81beec4e715bf388bbe9921092daa")
EMPTY_KEY = bytes.fromhex("a93a964a8fca51217088d72b82e0a910644a28658fcfd2da25f3ac4f970246e3")


def encrypted(prefix=b"v10", ciphertext=V10):
    return base64.b64encode(prefix + ciphertext).decode()


def plaintext(raw=TOKEN.encode()):
    return "plaintext:v1:" + base64.b64encode(raw).decode()


@unittest.skipUnless(sys.platform == "linux", "Linux extractor")
class LinuxTokenTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="grok-bot-linux-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("bash", "python3"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin), XDG_CONFIG_HOME=str(self.root / "config"))
        for name in ("XDG_CURRENT_DESKTOP", "KDE_SESSION_VERSION", "GROK_BOT_ACCESS_TOKEN"):
            self.env.pop(name, None)
        self.store = self.root / "config/Grok Bot/sand-secrets.json"
        self.store.parent.mkdir(parents=True)

    def write_store(self, data):
        self.store.write_text(json.dumps(data), encoding="utf-8")

    def save_token(self, value):
        self.write_store({"version": 1, "cursor-access-token": value})

    def run_script(self, *args):
        before = self.store.read_bytes() if self.store.exists() else None
        result = subprocess.run([str(SCRIPT), *args], env=self.env, capture_output=True, timeout=5)
        after = self.store.read_bytes() if self.store.exists() else None
        self.assertEqual(before, after, "The extractor must not change the credential store")
        return result

    def assert_token(self, result, token=TOKEN):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, (token + "\n").encode())
        self.assertEqual(result.stderr, b"")

    def assert_error(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(message.encode(), result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)

    def tool(self, name, body):
        target = self.bin / name
        target.write_text("#!/usr/bin/env python3\nimport sys\n" + body, encoding="utf-8")
        target.chmod(0o755)

    def keyring(self, name="secret-tool", password=PASSWORD, wallet="kdewallet"):
        arguments = (
            ["lookup", "application", "Grok Bot"] if name == "secret-tool"
            else ["-f", "Chromium Keys", "-r", "Chromium Safe Storage", "--", wallet]
        )
        self.tool(name, f"assert sys.argv[1:] == {arguments!r}\nsys.stdout.write({password!r})\n")

    def test_v10_without_keyring(self):
        self.save_token(encrypted())
        self.assert_token(self.run_script())

    def test_active_account_and_scoped_token(self):
        self.write_store({
            "version": 1,
            "cursor-access-token": plaintext(b"stale.token"),
            "cursor-accounts": json.dumps({
                "active": "chosen",
                "accounts": {
                    "other": {"cursor-access-token": plaintext(b"wrong.account")},
                    "chosen": {"cursor-access-token": "scoped:v1:" + "a" * 64 + ":" + encrypted()},
                },
            }),
        })
        self.assert_token(self.run_script())

    def test_missing_active_account_never_falls_back(self):
        for saved in (
            {"active": None, "accounts": {"other": {"cursor-access-token": plaintext()}}},
            {"active": "missing", "accounts": {"other": {"cursor-access-token": plaintext()}}},
            {"active": "chosen", "accounts": {"chosen": {}}},
            {"active": [], "accounts": {}},
            {"active": "chosen", "accounts": []},
            None,
        ):
            with self.subTest(saved=saved):
                self.write_store({"cursor-accounts": json.dumps(saved), "cursor-access-token": plaintext()})
                self.assert_error(self.run_script(), "active Grok Bot account")

    def test_plaintext_legacy_and_scoped(self):
        for value in (plaintext(), "scoped:v1:" + "b" * 64 + ":" + plaintext()):
            with self.subTest(value=value):
                self.write_store({"cursor-access-token": value})
                self.assert_token(self.run_script())

    def test_v11_secret_service(self):
        self.save_token(encrypted(b"v11", V11))
        self.keyring()
        self.assert_token(self.run_script("--keyring", "secret-service"))

    def test_v11_kwallet_and_custom_wallet(self):
        self.save_token(encrypted(b"v11", V11))
        self.keyring("kwallet-query", password=PASSWORD + "\n", wallet="my network wallet")
        self.assert_token(self.run_script("--keyring", "kwallet", "--kwallet-name", "my network wallet"))

    def test_auto_prefers_kde_keyring(self):
        self.env["XDG_CURRENT_DESKTOP"] = "KDE"
        self.save_token(encrypted(b"v11", V11))
        self.keyring("kwallet-query6", PASSWORD + "\n")
        marker = self.root / "unexpected-secret-tool-call"
        self.tool("secret-tool", f"open({str(marker)!r}, 'w').close()\n")
        self.assert_token(self.run_script())
        self.assertFalse(marker.exists())

    def test_auto_tries_another_keyring_after_wrong_key(self):
        self.save_token(encrypted(b"v11", V11))
        self.keyring(password="wrong-password")
        self.keyring("kwallet-query")
        self.assert_token(self.run_script())
        self.assert_error(self.run_script("--keyring", "secret-service"), "could not decrypt")

    def test_historical_empty_key_fallback(self):
        self.keyring()
        for prefix in (b"v10", b"v11"):
            with self.subTest(prefix=prefix):
                self.save_token(encrypted(prefix, EMPTY_KEY))
                self.assert_token(self.run_script())

    def test_helper_errors_do_not_leak_output(self):
        self.save_token(encrypted(b"v11", V11))
        self.tool("secret-tool", "print('private-output')\nprint('private-diagnostic', file=sys.stderr)\nsys.exit(1)\n")
        result = self.run_script("--keyring", "secret-service")
        self.assert_error(result, "could not read the saved key")
        self.assertNotIn(b"private-", result.stderr)

    def test_missing_keyring_tools(self):
        self.save_token(encrypted(b"v11", V11))
        result = self.run_script()
        self.assert_error(result, "secret-tool was not found")
        self.assertIn(b"kwallet-query was not found", result.stderr)

    def test_keyring_timeout_does_not_leak_partial_output(self):
        self.save_token(encrypted(b"v11", V11))
        self.tool("secret-tool", "import time\nprint('private-output', flush=True)\ntime.sleep(10)\n")
        result = self.run_script("--keyring", "secret-service", "--timeout", "0.1")
        self.assert_error(result, "timed out")
        self.assertNotIn(b"private-output", result.stderr)

    def test_invalid_timeout(self):
        for value in ("0", "-1", "nan", "inf", "text"):
            with self.subTest(value=value):
                self.assert_error(self.run_script("--timeout", value), "positive, finite")

    def test_invalid_credentials(self):
        cases = (
            ({"version": 2}, "Unsupported"),
            ([], "Unsupported"),
            ({}, "does not contain an access token"),
            ({"cursor-access-token": "scoped:v1:bad:" + encrypted()}, "Invalid scoped"),
            ({"cursor-access-token": "not base64!"}, "not valid base64"),
            ({"cursor-access-token": encrypted(b"v20")}, "Unsupported"),
            ({"cursor-access-token": encrypted(b"v10", b"short")}, "Unsupported"),
            ({"cursor-access-token": encrypted(b"v10", bytes(32))}, "Could not decrypt"),
            ({"cursor-access-token": plaintext(b"\xff")}, "not valid UTF-8"),
            ({"cursor-access-token": plaintext(b"line1\nline2")}, "invalid format"),
            ({"cursor-accounts": "{"}, "active Grok Bot account"),
        )
        for data, message in cases:
            with self.subTest(data=data):
                self.write_store(data)
                self.assert_error(self.run_script(), message)

    def test_missing_and_unreadable_store(self):
        self.assert_error(self.run_script(), "login was not found")
        for raw in (b"{invalid-json", b"\xff"):
            with self.subTest(raw=raw):
                self.store.write_bytes(raw)
                self.assert_error(self.run_script(), "Could not read")

    def test_explicit_store_overrides_xdg_config_home(self):
        self.save_token(encrypted())
        self.env["XDG_CONFIG_HOME"] = str(self.root / "no-login-here")
        self.assert_token(self.run_script("--secrets-file", str(self.store)))

    def test_help_without_login_or_keyring(self):
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"--secrets-file", result.stdout)
        self.assertEqual(result.stderr, b"")

    def test_chromium_known_answer(self):
        # Chromium's upstream vector tests the cipher without a locally generated round trip.
        # 로컬에서 암호화한 값을 되돌리는 대신 Chromium의 공식 검증값으로 암호를 확인한다.
        source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        definitions = source.rsplit("\ntry:\n    main()", 1)[0]
        namespace = {}
        exec(compile(definitions, str(SCRIPT), "exec"), namespace)
        ciphertext = bytes.fromhex(
            "772100608709e894de634f803640b7dd80e12c6f9ab66bba93afecb589e61228"
            "f085a2bbf9303087f8d1104e97e17573"
        )
        self.assertEqual(
            namespace["decrypt_cbc"](ciphertext, PASSWORD.encode()),
            b"Hello, World! This is a longer string.",
        )


if __name__ == "__main__":
    unittest.main()
