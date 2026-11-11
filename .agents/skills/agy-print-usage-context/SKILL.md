---
name: agy-print-usage-context
description: agent-scripts의 Antigravity 사용량 조회 스크립트(agy-print-usage.sh)를 수정하거나 그 옵션·출력 형식에 관한 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 전제를 적용합니다.
---

# Antigravity 사용량 조회 맥락

확인일: 2026-11-11. 이 프로젝트 작업에서 확인한 대화 맥락과 외부 전제 12개를 기록합니다.

1. **사용 목적과 초기 명명 변경:** 사용자는 처음에 `agy -p "/usage"`를 기반으로 `agy-usage.sh` 작성을 요청했으나, 이후 Antigravity CLI의 print 모드 플래그를 명시하는 이름인 `agy-print-usage.sh`로 변경을 요구했습니다.

2. **`--output-format-json` 옵션 지정:** 사용자가 `agy` CLI의 `--output-format` 플래그를 반영하여 스크립트에 `--output-format-json` 옵션을 직접 명명하고 추가하도록 요구했습니다.

3. **`--summary` 제거와 지적:** 기존 저장소 스크립트(`claude-usage.sh`, `grok-billing.sh`)의 관례를 보고 임의로 넣었던 `--summary` 블록 요약 옵션에 대해, 사용자가 `"--summary" 누가 넣으라 그러데?`라고 지적하여 스크립트에서 완전히 제거했습니다.

4. **글로벌 지침 추가 배경과 파일 위치:** 사용자의 지시로 `~/.gemini/config/GEMINI.md`(실제 파일: `dotfiles/dotfiles/.gemini-working/config/GEMINI.md`)에 "요구사항 준수 및 임의 확장 금지 규칙"을 추가하고 dotfiles 저장소에 커밋했습니다.

5. **`--timeout` 제거 배경:** 사용자가 `--timeout 꼭 필요해???`라고 질의했고, `agy --print "/usage"`는 네트워크 API 직접 호출이 아닌 로컬 CLI 내장 슬래시 명령어로 즉시(0.1초 미만) 반환되어 타임아웃 처리가 불필요함을 확인한 후 사용자 지시(`제거해.`)로 완전히 제거했습니다.

6. **단축 옵션 `-p` 대신 긴 옵션 `--print` 요구:** 사용자가 `agy -p "/usage" ==> agy --print "/usage"`로 긴 옵션을 사용하도록 명시적으로 지시하여, 호출 명령 및 주석/안내 문구를 모두 `--print`로 통일했습니다.

7. **`agy` 실행 파일 특성:** `agy`는 `/Users/xiote/.local/bin/agy`에 위치한 Mach-O 64-bit arm64 독립 실행 바이너리입니다.

8. **`agy`의 CLI 및 JSON 응답 구조:** `agy --output-format json` 실행 시 최상위에 `conversation_id`, `status`("SUCCESS"), `response`(탭 구분 원본 문자열), `duration_seconds: 0`, `num_turns: 0`, `usage`, `command` 객체(`name: "usage"`, `data: {description, groups}`)가 반환됩니다.

9. **쿼터 모델 그룹 및 버킷 구성:** 실제 계정에서 `Gemini Models`(5h, weekly), `Claude and GPT models`(5h, weekly), `Gemini 4 Argon`(weekly)의 3개 그룹이 반환됩니다.

10. **`remaining_fraction`의 수치 방향:** `remaining_fraction`은 0.0~1.0 사이의 실수값으로, 소진율이 아니라 '남은 한도 비율(fraction remaining)'을 나타냅니다.

11. **`~/.gemini` 디렉터리의 실체:** `~/.gemini`는 `/Users/xiote/dotfiles/dotfiles/.gemini-working`으로의 심볼릭 링크입니다.

12. **`.claude/skills`와 `.agents/skills` 심볼릭 링크:** 프로젝트 내 `.claude/skills`는 `../.agents/skills`를 가리키는 심볼릭 링크로 설정되어 있어 `.agents/skills`에 스킬을 두면 Claude Code와 Antigravity 양쪽에서 모두 인식됩니다.

코드와 주석에서 바로 알 수 있어 기록하지 않은 사실 7개: bash 셸 및 `set -euo pipefail` 사용, 유효 옵션(`-h`, `--help`, `--output-format-json`, `--json`) 및 알 수 없는 인자 에러 처리, 기본 실행 시 `exec agy --print "/usage"`로 원본 표 출력, `--output-format-json` 시 python3의 `json.dumps(..., indent=2)`로 포맷팅 출력, `agy` 및 `python3` PATH 검사, `agy` 실행 실패 시 에러 메시지 및 exit code 처리, 저장소 루트의 `agy-print-usage.sh` 경로.
