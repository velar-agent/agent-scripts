#!/usr/bin/env bash
# Decrypt the active Grok Bot account's saved access token and echo it to stdout.
# Grok Bot 활성 계정에 저장된 액세스 토큰을 복호화해 표준 출력으로 표시한다.
# Read the credential store and Linux keyring without modifying or refreshing credentials.
# 인증 저장소와 Linux 키링을 읽으며 인증 정보를 변경하거나 갱신하지 않는다.

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
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

APP_NAME = "Grok Bot"
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
        raise RuntimeError(
            f"Grok Bot login was not found at {path}. Open Grok Bot and sign in, or use --secrets-file."
        ) from None
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
            if not isinstance(active, str) or not active:
                raise ValueError
            value = saved["accounts"][active][TOKEN_KEY]
        except (ValueError, KeyError, TypeError):
            raise RuntimeError(
                "No access token was found for the active Grok Bot account. Open Grok Bot and sign in."
            ) from None
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


def read_keyring_password(backend, wallet, deadline):
    if backend == "secret-service":
        executable = shutil.which("secret-tool")
        if executable is None:
            raise RuntimeError("secret-tool was not found in PATH (install libsecret-tools on Debian/Ubuntu)")
        # Electron uses the app name, including its case, as the application attribute.
        # Electron은 대소문자를 유지한 앱 이름을 application 속성으로 사용한다.
        command = [executable, "lookup", "application", APP_NAME]
    else:
        executable = next(
            (path for name in ("kwallet-query", "kwallet-query6", "kwallet-query5")
             if (path := shutil.which(name)) is not None),
            None,
        )
        if executable is None:
            raise RuntimeError("kwallet-query was not found in PATH (install the KWallet query tool)")
        # Electron's synchronous KWallet backend uses Chromium's shared folder and entry.
        # Electron의 동기 KWallet 백엔드는 Chromium 공용 폴더와 항목을 사용한다.
        command = [executable, "-f", "Chromium Keys", "-r", "Chromium Safe Storage", "--", wallet]
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("keyring access timed out; unlock the keyring and retry")
    try:
        result = subprocess.run(
            command, stdin=subprocess.DEVNULL, capture_output=True, timeout=remaining,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("keyring access timed out; unlock the keyring and retry") from None
    except OSError:
        raise RuntimeError(f"could not execute the {backend} query tool") from None
    password = result.stdout.rstrip(b"\r\n")
    if result.returncode != 0 or not password:
        hint = " Check --kwallet-name if your network wallet is not kdewallet." if backend == "kwallet" else ""
        raise RuntimeError(
            "could not read the saved key; run as the Grok Bot user in the same desktop session "
            "and unlock the keyring." + hint
        )
    return password


def decrypt_cbc(ciphertext, password):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.padding import PKCS7
    except ImportError:
        raise RuntimeError(
            "The Python 'cryptography' package is required. Install it for the python3 used by this script."
        ) from None
    # Linux safeStorage uses one PBKDF2-SHA1 iteration, AES-128-CBC and PKCS7 padding.
    # Linux safeStorage는 PBKDF2-SHA1 1회 반복, AES-128-CBC, PKCS7 패딩을 사용한다.
    # Source / 근거: Electron v43.8.9, components/os_crypt/sync/os_crypt_linux.cc:
    # https://github.com/electron/electron/blob/v43.8.9/patches/chromium/revert_oscrypt_remove_sync_backend.patch
    key = hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1, dklen=16)
    decryptor = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).decryptor()
    padded = decryptor.update(ciphertext) + decryptor.finalize()
    unpadder = PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def validate_token(raw):
    try:
        token = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ValueError("The decrypted Grok Bot access token is not valid UTF-8.") from None
    if re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", token) is None:
        raise ValueError("The decrypted Grok Bot access token has an invalid format.")
    return token


def decrypt_with_password(ciphertext, password):
    # Chromium retries with an empty password for data affected by its historical keyring bug.
    # Chromium은 과거 키링 버그로 저장된 데이터를 빈 비밀번호로 재시도한다.
    for candidate in (password, b""):
        try:
            return validate_token(decrypt_cbc(ciphertext, candidate))
        except ValueError:
            pass
    raise ValueError("Could not decrypt the saved Grok Bot token with the selected Linux key.")


def decrypt_token(value, args):
    plaintext = value.startswith("plaintext:v1:")
    encoded = value[len("plaintext:v1:"):] if plaintext else value
    try:
        blob = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise RuntimeError("The saved Grok Bot access token is not valid base64.") from None
    if plaintext:
        return validate_token(blob)
    if blob[:3] not in (b"v10", b"v11") or len(blob) <= 3 or (len(blob) - 3) % 16:
        raise RuntimeError("Unsupported Grok Bot token encryption format; expected Linux safeStorage v10 or v11.")
    if blob.startswith(b"v10"):
        return decrypt_with_password(blob[3:], b"peanuts")

    backends = [args.keyring]
    if args.keyring == "auto":
        desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper().split(":")
        kde = "KDE" in desktop or bool(os.environ.get("KDE_SESSION_VERSION"))
        backends = ["kwallet", "secret-service"] if kde else ["secret-service", "kwallet"]
    deadline = time.monotonic() + args.timeout
    failures = []
    for backend in backends:
        try:
            password = read_keyring_password(backend, args.kwallet_name, deadline)
        except RuntimeError as error:
            failures.append(f"{backend}: {error}")
            continue
        try:
            return decrypt_with_password(blob[3:], password)
        except ValueError:
            failures.append(f"{backend}: the saved key could not decrypt this token")
    raise RuntimeError("Could not decrypt the Grok Bot v11 token. " + "; ".join(failures))


def main():
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    parser = argparse.ArgumentParser(
        prog="grok-bot-cursor-token-from-linux.sh",
        description="Print the active Grok Bot account's decrypted access token to stdout.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Requires Linux, python3, and the Python cryptography package for encrypted tokens.\n"
            "v10 (basic_text) needs no keyring tool. v11 needs secret-tool (Secret Service)\n"
            "or kwallet-query (KWallet) in the same user's desktop/D-Bus session.\n"
            "Tokens and keyring entries are not created, refreshed, or saved to .env.\n\n"
            "Example (run from the script directory):\n"
            '  token="$(./grok-bot-cursor-token-from-linux.sh)" && \\\n'
            '    GROK_BOT_ACCESS_TOKEN="$token" ./grok-bot-cursor-usage.sh --summary'
        ),
    )
    parser.add_argument(
        "--secrets-file", type=Path,
        default=config_home / APP_NAME / "sand-secrets.json",
        metavar="PATH", help="credential store (default: ${XDG_CONFIG_HOME:-~/.config}/Grok Bot/sand-secrets.json)",
    )
    parser.add_argument(
        "--keyring", choices=("auto", "secret-service", "kwallet"), default="auto",
        help="keyring to read for v11 tokens (default: auto, try the desktop's keyring first)",
    )
    parser.add_argument(
        "--kwallet-name", default="kdewallet", metavar="NAME",
        help="KWallet network wallet name (default: kdewallet)",
    )
    parser.add_argument(
        "--timeout", type=positive_timeout, default=60.0,
        metavar="SECONDS", help="maximum total time for keyring access (default: 60)",
    )
    args = parser.parse_args()
    if sys.platform != "linux":
        raise RuntimeError("This script supports Grok Bot on Linux only.")
    print(decrypt_token(read_saved_token(args.secrets_file), args))


try:
    main()
except (OSError, RuntimeError, ValueError, OverflowError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
)

echo "$token"
