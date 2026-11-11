---
name: agy-print-usage-context
description: agent-scripts의 Antigravity 사용량 조회 스크립트(agy-print-usage.sh)를 수정하거나 그 옵션·출력 형식에 관한 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 전제를 적용합니다.
---

# Antigravity 사용량 조회 맥락

확인일: 2026-11-11. 이 프로젝트 작업에서 확인한 대화 맥락과 외부 전제들을 기록합니다.

1. **사용 목적과 인터페이스 기준:** 사용자는 `agy --print "/usage"`를 이용하여 Antigravity의 구독 한도를 조회하는 `agy-print-usage.sh` 도구를 요청했습니다. 기본 실행 시 `agy --print "/usage"` 원본 텍스트 표를 출력하고, `--output-format-json` 옵션 사용 시 들여쓰기된 JSON을 출력하도록 구성했습니다. 사용자가 요구하지 않은 임의의 추가 옵션은 일체 넣지 않습니다.

2. **CLI 호출 및 엔드포인트 근거:** `agy` CLI는 `--output-format json` 옵션을 제공하며, `--print "/usage"`를 실행하면 `command.name: "usage"`와 함께 구조화된 JSON 데이터(`command.data`)를 포함한 JSON을 출력합니다.

3. **기본 동작:**
   - 옵션 없이 실행 시 `agy --print "/usage"`를 실행하여 터미널 포맷 표(`Quota:\n...`)를 그대로 출력합니다.

4. **`--output-format-json` 옵션:**
   - `agy --output-format json --print "/usage"`의 응답 결과를 파싱하여 보기 좋은 2칸 들여쓰기 JSON으로 출력합니다.

5. **스크립트 위치:**
   - 저장소 루트의 `agy-print-usage.sh`에 위치합니다.
