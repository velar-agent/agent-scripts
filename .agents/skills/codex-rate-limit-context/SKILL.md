---
name: codex-rate-limit-context
description: agents-script의 Codex 계정 한도 조회 도구를 수정하거나 인증 관련 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 인증 전제를 적용합니다.
---

# Codex 계정 한도 조회 맥락

확인일: 2026-11-06. 이 프로젝트 작업에서 확인한 대화 맥락과 외부 전제 8개를 기록합니다.

1. **사용 목적:** 사용자는 Codex CLI의 `/status`에 표시되는 `Weekly limit`을 터미널에서 간단히 확인하고자 이 도구를 요청했습니다. 후속 기능을 설계할 때 이 사용 목적을 고려합니다.

2. **프로젝트 선택:** 사용자는 이 도구의 보관 위치를 `agents-script` 저장소로 명시적으로 지정했습니다. 이 도구의 후속 변경은 이 프로젝트에서 진행합니다.

3. **인증 문의의 상태:** 사용자는 미로그인 시 안내와 `.env`를 통한 인증 가능 여부를 질문했습니다. 이 대화에서 `.env` 기반 인증 도입을 결정하지는 않았으므로, 이미 합의된 구현 요구로 간주하지 않습니다.

4. **CLI 확인 기록:** 확인 당시 설치된 Codex CLI는 `0.166.0`이었고, 도움말에 독립적인 `codex status` 하위 명령은 없었습니다. 기본 명령으로 이 도구를 대체할 수 있는지 검토할 때는 설치된 버전의 도움말을 다시 확인합니다. 근거는 당시 실행한 `codex --version`과 `codex --help`입니다.

5. **계정 한도의 인증 범위:** 조회 대상은 ChatGPT 계정의 사용 한도이며, 일반 Platform API 키는 이 계정 인증을 대체하지 않습니다. `.env`에 일반 API 키를 넣는 것만으로 해당 한도를 조회할 수 있다고 안내하지 않습니다. 근거: [App Server의 ChatGPT 한도 조회](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt), [인증 방식](https://learn.chatgpt.com/docs/auth).

6. **로그인 수명 관리:** Codex는 로그인 정보를 로컬 인증 저장소에 캐시해 재사용하고, ChatGPT 로그인 토큰을 사용 중에 자동 갱신합니다. 인증 문제를 다룰 때는 이 수명 관리를 전제로 하며 매번 브라우저 로그인이 필요하다고 가정하지 않습니다. 근거: [로그인 캐시](https://learn.chatgpt.com/docs/auth#login-caching).

7. **환경변수 인증의 제공 범위:** 확인 당시 공식 문서는 Codex CLI와 app-server의 `CODEX_ACCESS_TOKEN` 환경변수 인증을 지원하며, 해당 액세스 토큰 발급은 ChatGPT Business·Enterprise 워크스페이스에 제공된다고 안내했습니다. 이 방식으로 인증을 변경할 때는 사용자의 워크스페이스에서 토큰 발급이 가능한지 최신 문서와 함께 확인합니다. 근거: [Codex 액세스 토큰](https://learn.chatgpt.com/docs/enterprise/access-tokens).

8. **초기화 시각의 표시 기준:** 사용자는 주간 한도 요약의 초기화 시각을 Codex CLI `/status`의 표시와 동일하게 맞추라고 명시적으로 요청했습니다. 이 항목의 출력 형식을 수정할 때는 사용자가 기준으로 제시한 CLI 표시와의 일치를 요구사항으로 취급합니다. 구체적인 날짜 포맷은 현재 코드에서 확인합니다.
