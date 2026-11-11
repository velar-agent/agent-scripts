#!/usr/bin/env bash
# agy --print "/usage" 명령으로 Antigravity 계정 사용량을 조회한다.
# 기본 출력은 원본 텍스트 표이며, --output-format-json 옵션 사용 시 JSON 형식으로 출력한다.

set -euo pipefail

print_help() {
  cat <<EOF
usage: $(basename "$0") [-h] [--output-format-json]

Print Antigravity usage limits using 'agy --print "/usage"'.

options:
  -h, --help              show this help message and exit
  --output-format-json    Print the usage result as JSON.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

output_format_json=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --output-format-json|--json)
      output_format_json=true
      shift
      ;;
    *)
      print_help >&2
      fail "unrecognized argument: $1"
      ;;
  esac
done

for cmd in agy python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd was not found in PATH."
done

# 기본 출력: 원본 agy --print "/usage" 텍스트 표 출력
if [[ "$output_format_json" == false ]]; then
  exec agy --print "/usage"
fi

response_file=$(mktemp)
error_file=$(mktemp)
trap 'rm -f "$response_file" "$error_file"' EXIT

agy_status=0
agy --output-format json --print "/usage" > "$response_file" 2> "$error_file" || agy_status=$?

if [[ "$agy_status" -ne 0 ]]; then
  err_msg=$(cat "$error_file")
  if [[ -n "$err_msg" ]]; then
    fail "agy command failed (exit code $agy_status): $err_msg"
  else
    fail "agy command failed with exit code $agy_status."
  fi
fi

python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

print(json.dumps(data, ensure_ascii=False, indent=2))
PY
