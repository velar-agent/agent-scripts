---
name: claude-usage-context
description: agent-scripts의 Claude 사용량 조회 스크립트(claude-usage.sh)를 수정하거나 그 인증·엔드포인트·출력 형식에 관한 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 전제를 적용합니다.
---

# Claude 사용량 조회 맥락

확인일: 2026-11-08. 이 프로젝트 작업에서 확인한 대화 맥락과 외부 전제 12개를 기록합니다.

1. **사용 목적과 인터페이스 기준:** 사용자는 Codex 한도 조회 스크립트처럼 Claude 구독의 세션·주간 한도를 터미널에서 확인하려고 이 도구를 요청했고, 파일 형식으로 `.sh`를 명시했습니다. 기본 JSON 출력, `--timeout` 기본 20초, 영문 CLI 메시지, 한국어 주석 등 인터페이스는 같은 저장소의 `codex-account-rateLimits-read.py`를 기준으로 맞췄습니다.

2. **엔드포인트 검증 근거:** `/api/oauth/usage`가 Claude Code `/usage` 화면이 호출하는 엔드포인트라는 사실은 Claude Code 2.1.319 바이너리(`~/.local/share/claude/versions/2.1.319`, Bun 실행 파일)에 든 `api/oauth/usage` 문자열과, 키체인 토큰에 `anthropic-beta: oauth-2025-04-20` 헤더를 붙여 호출해 받은 200 응답으로 확인했습니다. 같은 기계의 `~/.claude/.credentials.json`(11월 2일자) 토큰으로는 401 `OAuth access token has been revoked.`를 받아, 키체인을 먼저 읽는 순서가 실제로 필요함을 확인했습니다.

3. **인증 범위:** 이 엔드포인트는 Claude Code 로그인(claude.ai OAuth Bearer 토큰)으로만 호출해 보았습니다. Anthropic 문서에 있는 사용량 API는 Admin API의 `usage_report`·`cost_report` 등(Admin API 키 필요, API 조직 대상)으로 구독 한도를 대신 조회하지 못하므로, Admin API 키나 일반 API 키로 이 한도를 볼 수 있다고 안내하지 않습니다.

4. **응답 구조(코드가 쓰지 않는 부분):** 응답에는 `five_hour`·`seven_day` 외에 `seven_day_sonnet`·`seven_day_opus`·`seven_day_cowork` 등 null 가능한 필드, `limits` 배열(`kind`가 `session`·`weekly_all`·`weekly_scoped`, 정수 `percent`, `is_active`, `scope.model.display_name`), `extra_usage`, `spend`(사용 금액·한도·크레딧 구매 가능 여부)와 다수의 프로모션용 null 필드가 들어옵니다. `utilization`은 실수 퍼센트, `resets_at`은 마이크로초가 붙은 `+00:00` ISO8601입니다.

5. **계정 맥락:** 확인 당시 계정은 Max 구독(`subscriptionType: max`)이었고, `limits`에 Fable 모델 범위 주간 한도(`weekly_scoped`, `is_active: true`)가 전체 주간 한도보다 높은 사용률로 들어와 `/usage`에 "Current week (Fable)" 행이 함께 표시됐습니다. 다른 요금제나 모델 구성에서는 행 구성이 달라질 수 있습니다.

6. **인증 설계 이유:** 토큰 갱신(refresh)은 Claude Code가 저장한 토큰을 바꿔 놓을 수 있어 넣지 않았고, `CLAUDE_CODE_OAUTH_TOKEN` 같은 환경변수 인증은 이 엔드포인트에서 동작하는지 확인하지 못해 넣지 않았습니다. 키체인 JSON의 `expiresAt`(밀리초 epoch)으로 만료를 미리 검사할 수도 있지만, 호출 후 401이면 `claude` 실행으로 갱신하라고 안내하는 방식만 씁니다. 이 두 인증 방식을 추가하려면 먼저 이 엔드포인트에서 동작하는지 확인합니다.

7. **Claude Code 화면과의 의도적 차이:** Claude Code는 "Current week (Sonnet only)" 행을 max·team 요금제에서만 보여 주고, 모델별 행(`weekly_scoped`)은 GrowthBook 원격 설정의 허용 목록(overage-included models allowlist)에 있는 모델만 표시합니다. 스크립트는 그 설정을 읽을 수 없어 Sonnet 행은 값이 있을 때, 모델별 행은 `weekly_scoped` 항목 전부를 표시합니다. 근거: 바이너리의 `/usage` 렌더링 코드.

8. **연도 표기는 추정:** "Nov 10 at 8pm"처럼 ` at `가 들어가는 날짜 형식은 Claude Code(Bun 내장 ICU)의 실제 출력이지만, 연도가 다를 때의 "Jan 3, 2027 at 8pm" 형태는 실제 화면이 아니라 추정입니다. 이 기계의 Homebrew node ICU는 같은 옵션을 "Jan 3, 2027, 8 PM"처럼 쉼표로 출력하므로 node로는 검증할 수 없고, bun은 설치되어 있지 않았습니다.

9. **초기화 시각 중복 제거 이유:** `weekly_all`과 `weekly_scoped`의 `resets_at`은 분 단위로 같지만 마이크로초가 다릅니다(예: `11:00:00.159048`과 `11:00:00.159521`). 그래서 요약에서는 포맷된 문자열 기준으로 중복을 제거하며, 실제로 시각이 다르면 둘 다 쉼표로 이어 표시합니다.

10. **python3 선택 이유:** 이 기계에는 `/usr/bin/jq`가 있지만, jq의 날짜 함수가 마이크로초가 붙은 ISO8601을 바로 다루지 못하는 것으로 판단했고 구형 macOS에는 jq가 없을 수 있어, Codex 스크립트와 같은 의존성인 python3(확인 당시 3.15.0)로 JSON 파싱과 현지 시간대 변환을 처리합니다.

11. **출력 형식 이력과 최종 사양:** 요약 옵션은 처음 `--weekly-limit`(Codex식 "Weekly limit: N% left")이었다가 사용자가 다른 이름을 요청해 추천한 `--summary`로 바뀌었습니다. 출력은 `/usage` 화면 문구를 그래프만 빼고 그대로 옮긴 형태를 거쳐, 사용자가 직접 지정한 두 블록 형식("Current session :" 아래 `  N% used, Resets …`, "Current week (all models, Fable) :" 아래 `  N% used, N% used, Resets …`)으로 확정됐습니다. 형식을 바꿀 때는 이 사용자 지정 형식을 요구사항으로 취급합니다.

12. **보관 위치:** 사용자가 위치를 지정하지 않아 스크립트는 Codex 스크립트 옆인 저장소 루트에 두었습니다. 이 스킬은 Claude Code가 프로젝트 스킬로 읽는 `.claude/skills/`에 두었는데, 기존 Codex 스킬이 있는 `.agents/skills/`는 Claude Code 2.1.319가 자동으로 읽지 않는 경로로 확인했기 때문입니다(바이너리에 다른 에이전트 설정 가져오기 경로로만 등장).

코드와 주석에서 바로 알 수 있어 기록하지 않은 사실 3개: 엔드포인트 URL과 요청 헤더, 키체인 우선 순서·자격 증명 파일 경로·토큰 미갱신, 행과 응답 필드의 대응·null 행 생략·시각 표기 규칙.
