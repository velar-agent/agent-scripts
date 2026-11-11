---
name: agy-usage-context
description: agent-scripts의 Antigravity 사용량 조회 스크립트(agy-usage.sh)를 수정하거나 그 옵션·출력 형식에 관한 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 전제를 적용합니다.
---

# Antigravity 사용량 조회 맥락

확인일: 2026-11-11. 이 프로젝트 작업에서 확인한 대화 맥락과 외부 전제들을 기록합니다.

1. **사용 목적과 인터페이스 기준:** 사용자는 `agy -p "/usage"`를 이용하여 Antigravity의 구독 한도(세션·주간 한도)를 조회하는 `agy-usage.sh` 도구를 요청했습니다. 기본 JSON 출력, `--summary` 요약, `--timeout` 기본 20초, 영문 CLI 메시지, 한국어 주석 등 인터페이스는 같은 저장소의 `claude-usage.sh`, `grok-billing.sh`를 기준으로 맞췄습니다.

2. **CLI 호출 및 엔드포인트 근거:** `agy` CLI는 `--output-format json` 및 `--print-timeout` 옵션을 제공하며, `-p "/usage"`를 실행하면 `command.name: "usage"`와 함께 구조화된 JSON 데이터(`command.data`)를 stdout으로 출력합니다.

3. **응답 데이터 구조:**
   - `command.data.groups`에 모델 그룹별(예: `Gemini Models`, `Claude and GPT models`, `Gemini 4 Argon`) 한도 정보가 배열로 전달됩니다.
   - 각 그룹에는 `buckets` 배열이 포함되며, 각 버킷은 `window`(`5h`, `weekly`), 잔여 비율 `remaining_fraction`(0.0~1.0 실수), 만료/초기화 시각 `reset_time`(ISO 8601 UTC)을 포함합니다.

4. **사용률 계산 및 방향:**
   - `agy`의 `remaining_fraction`은 남은 비율(fraction left)입니다.
   - `claude-usage.sh` 및 `usage-plan.sh`의 사용량 기준(% used, %u)과의 일관성을 위해, 사용률은 `100 - round(remaining_fraction * 100)`으로 변환하여 `% used`로 표기합니다.

5. **`--summary` 형식과 소진계획 호환성:**
   - `claude-usage.sh`의 요약 형식과 동일하게 세션 한도(`Current session`)와 주간 한도(`Current week`) 두 블록으로 분류하여 출력합니다.
   - 각 블록의 제목에는 모델 그룹명을 나열하고, 본문에는 `% used`와 로컬 시간대 기준 `Resets ...` 시각을 표시하여 차후 `usage-plan.sh`와의 파싱 연동이 매끄럽게 가능하도록 설계했습니다.

6. **`--raw` 옵션:**
   - `agy -p "/usage"`의 원래 텍스트 출력(터미널 포맷 표: `Quota:\n...`)을 그대로 확인하고자 할 때를 위해 `--raw` 옵션을 지원합니다.

7. **스크립트 위치:**
   - 다른 조회 도구들과 동일하게 저장소 루트의 `agy-usage.sh`에 위치합니다.
