#!/usr/bin/env bash
# Decrypt the active Grok Bot account's saved access token and echo it to stdout.
# Grok Bot 활성 계정에 저장된 액세스 토큰을 복호화해 표준 출력으로 표시한다.
# Read the credential store and macOS Keychain without modifying or refreshing them.
# 인증 저장소와 macOS 키체인을 변경하거나 갱신하지 않고 읽는다.
# Windows implementation notes: docs/grok-bot-cursor-token-windows.md.
# Windows 구현 시 docs/grok-bot-cursor-token-windows.md를 참고한다.

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 was not found in PATH." >&2
  exit 1
fi

token=$(python3 - "$@" <<'PY'
import argparse
import base64
import binascii
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

KEYCHAIN_SERVICE = "Grok Bot Safe Storage"
KEYCHAIN_ACCOUNT = "Grok Bot Key"
TOKEN_KEY = "cursor-access-token"


def positive_timeout(value):
    try:
        number = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("timeout must be a positive, finite number") from None
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("timeout must be a positive, finite number")
    return number


def read_saved_token(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RuntimeError("Grok Bot login was not found. Open Grok Bot and sign in first.") from None
    except (OSError, ValueError):
        raise RuntimeError(f"Could not read the Grok Bot credential store: {path}") from None
    if not isinstance(data, dict) or data.get("version") not in (None, 1):
        raise RuntimeError("Unsupported Grok Bot credential store format.")
    if "cursor-accounts" in data:
        # Select only the active account; never fall back to another saved account.
        # 활성 계정만 선택하며 다른 저장 계정으로 대체하지 않는다.
        try:
            saved = json.loads(data["cursor-accounts"])
            active = saved["active"]
            account = saved["accounts"][active]
            value = account[TOKEN_KEY]
        except (ValueError, KeyError, TypeError):
            raise RuntimeError("No access token was found for the active Grok Bot account. Open Grok Bot and sign in.") from None
    else:
        # Older app versions stored the token at the top level.
        # 이전 앱 버전은 토큰을 최상위 항목에 저장했다.
        value = data.get(TOKEN_KEY)
    if not isinstance(value, str) or not value:
        raise RuntimeError("Grok Bot login does not contain an access token. Open Grok Bot and sign in.")
    if value.startswith("scoped:v1:"):
        parts = value.split(":", 3)
        if len(parts) != 4 or re.fullmatch(r"[0-9a-f]{64}", parts[2]) is None:
            raise RuntimeError("Invalid scoped Grok Bot credential format.")
        value = parts[3]
    return value


def read_keychain_password(timeout):
    security = shutil.which("security")
    if security is None:
        raise RuntimeError("security was not found in PATH. This script requires macOS Keychain access.")
    try:
        result = subprocess.run(
            [security, "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Keychain access timed out. Retry and allow the macOS Keychain prompt if shown.") from None
    password = result.stdout.rstrip(b"\r\n")
    if result.returncode != 0 or not password:
        raise RuntimeError("Could not read Grok Bot Safe Storage. Unlock the macOS Keychain and allow access if prompted.")
    return password


def decrypt_token(value, timeout):
    plaintext = value.startswith("plaintext:v1:")
    encoded = value[len("plaintext:v1:"):] if plaintext else value
    try:
        blob = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise RuntimeError("The saved Grok Bot access token is not valid base64.") from None
    if plaintext:
        return blob
    if not blob.startswith(b"v10") or len(blob) <= 3 or (len(blob) - 3) % 16:
        raise RuntimeError("Unsupported Grok Bot token encryption format; expected Electron safeStorage v10.")
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.padding import PKCS7
    except ImportError:
        raise RuntimeError("The Python 'cryptography' package is required. Install it for the python3 used by this script.") from None
    password = read_keychain_password(timeout)
    # Match Electron safeStorage on macOS: PBKDF2-SHA1 and AES-128-CBC with PKCS7 padding.
    # macOS Electron safeStorage의 PBKDF2-SHA1 및 PKCS7 패딩을 쓰는 AES-128-CBC 방식에 맞춘다.
    key = hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, dklen=16)
    decryptor = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).decryptor()
    padded = decryptor.update(blob[3:]) + decryptor.finalize()
    unpadder = PKCS7(128).unpadder()
    try:
        return unpadder.update(padded) + unpadder.finalize()
    except ValueError:
        raise RuntimeError("Could not decrypt the saved Grok Bot token with its Keychain key.") from None


def main():
    parser = argparse.ArgumentParser(
        prog="grok-bot-cursor-token-from-macos-keychain.sh",
        description="Print the active Grok Bot account's decrypted access token to stdout.",
        epilog="Requires macOS, python3, and the Python cryptography package. Tokens are not refreshed or saved to .env.",
    )
    parser.add_argument(
        "--secrets-file", type=Path,
        default=Path.home() / "Library/Application Support/Grok Bot/sand-secrets.json",
        metavar="PATH", help="credential store (default: the Grok Bot app's sand-secrets.json)",
    )
    parser.add_argument(
        "--timeout", type=positive_timeout, default=60.0,
        metavar="SECONDS", help="maximum time for Keychain access (default: 60)",
    )
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("This script supports Grok Bot on macOS only.")
    raw = decrypt_token(read_saved_token(args.secrets_file), args.timeout)
    try:
        token = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise RuntimeError("The decrypted Grok Bot access token is not valid UTF-8.") from None
    if re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", token) is None:
        raise RuntimeError("The decrypted Grok Bot access token has an invalid format.")
    print(token)


try:
    main()
except (OSError, RuntimeError, ValueError, OverflowError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
)

echo "$token"
