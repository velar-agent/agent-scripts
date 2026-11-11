---
name: muse-usage-context
description: agent-scripts의 Muse 사용량 조회 스크립트(muse-usage.sh)를 수정하거나 그 인증·엔드포인트·출력 형식에 관한 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 전제를 적용합니다.
---

# Muse 사용량 조회 맥락

확인일: 2026-11-12. Muse 사용량 API 조사와 muse-usage.sh 작성 과정에서 확인한 대화 맥락과 외부 전제 17개를 기록합니다. 스크립트에 그대로 드러나는 인터페이스·출력 형식·JSON 키는 여기 적지 않습니다.

1. **`muse usage` 옵션은 `--json`뿐:** Muse Code 1.4.15의 `muse usage` 도움말에 타임아웃 같은 다른 옵션이 없다. 스크립트가 `muse usage --json` 한 가지만 호출하는 이유다.

2. **수치의 실제 출처는 키 발급 응답:** 사용률·초기화 시각은 `muse` CLI가 `POST https://api.meta.ai/muse-code/key` 응답의 `subs_usage`에서 읽은 값이다. CLI JSON의 `"source": "mint"`가 그 흔적이며, 별도 사용량 조회 호출은 하지 않는다.

3. **키 발급 호출 규격:** `Authorization: Bearer <device-code dca 토큰>`, `x-api-version: 1.0.0` 헤더에 본문 `{"onboard":false}`로 호출하면 200 응답에 `api_key`·`subs_tier_name`·`subs_usage(window·weekly)`가 온다. 비공개 엔드포인트라 스펙 변경과 호출 빈도 제한에 유의한다.

4. **토큰 위치:** Muse 로그인은 macOS 키체인(`ai.meta.dev.credentials`/`meta` 항목 안 JSON의 `access_token`) 또는 `~/.config/muse/auth.json`의 인라인 `providers.meta.access_token`에 있다. 이 기계는 키체인 방식(`"storage": "keychain"`)이다. 스크립트는 토큰을 직접 다루지 않고 조회 전체를 `muse` CLI에 맡긴다.

5. **전용 사용량 경로는 없다:** `/v1/usage`·`/v1/billing`·`/v1/subscription`·`/v1/me`류 추측 경로는 모두 404다(외부 역공학 문서 교차 확인). 키 발급 응답이 유일한 구독 스냅샷 출처다.

6. **초 단위와 밀리초 단위:** 직접 API의 `resets_at`은 유닉스 초, CLI JSON의 `resetsAtMs`·`asOfMs`는 밀리초다. 실측에서 같은 초기화 시각이 양쪽에 초·밀리초로 일치함을 확인했다.

7. **런처 구조:** `muse`는 셸 런처이며 실체 바이너리는 `muse-bin-<버전>`이다. 런처는 시간당 한 번씩 업데이트를 확인하고, 로그인은 `auth.meta.com` device-code 플로우다.

8. **Muse 소유 전역 지침 경로:** `$CONFIG_DIR/AGENTS.md`이며, `XDG_CONFIG_HOME`이 비어 있는 이 기계에서는 `~/.config/muse/AGENTS.md`다. 문서에 경로가 명시되어 있지 않아 새 세션 프로브로 확인했다.

9. **전역 지침 우선순위(가림):** 그 파일이 있으면 `~/.claude/CLAUDE.md`를 건너뛰고 그것만 로드한다. `/tmp` 미신뢰 작업공간의 새 세션 2회 프로브에서 로드 목록이 `$CONFIG_DIR/AGENTS.md` 1건뿐이었고, 클로드 규칙의 한국어 합쇼체 요구도 적용되지 않았다.

10. **전역 지침 폴백:** 그 파일이 없을 때만 `~/.claude/CLAUDE.md`를 대신 읽는다. 이 세션은 파일 생성 전(00:34 시작, 파일 00:58 생성)이라 클로드 규칙이 적용 중이다. 바이너리에는 `~/.codex/AGENTS.md` 후보도 있으나 순서는 미확인이다.

11. **`MUSE.md`는 읽히지 않는다:** 바이너리 문자열에 `MUSE.md`가 0건이고, 심링크가 존재하던 시점의 프로브 로드 목록에도 없었다.

12. **설정 디렉터리 실체:** 이 기계의 `~/.config/muse`는 `/Users/xiote/dotfiles/dotfiles/.muse-working`의 심링크다. 전역 지침을 고칠 때는 실체 경로 기준으로 읽고 쓴다.

13. **인터페이스 패턴 선택:** 사용자는 기본 JSON 출력(claude-usage.sh식) 대신 기본 텍스트 요약+`--json`(agy-print-usage.sh식)을 선택했다. 기본 출력이 곧 요약이므로 요약 전용 옵션은 두지 않는다.

14. **`--summary` 제거:** 기본 출력과 같은 텍스트의 명시적 별칭으로 두었으나, 사용자가 필요 없다고 판단해 제거했다. 다시 넣지 않는다.

15. **`--timeout` 제거:** `muse`에 전달되는 값이 아니라 밖에서 프로세스를 감시하는 방식이라 거추장스럽다는 이유로 제거했다. 사용자는 심플하게 필요한 것만 두는 쪽을 요구했다. `muse usage` 자체에 타임아웃 옵션이 없는 것도 근거다.

16. **표본 끝 쉼표는 문장 부호:** 사용자가 제시한 출력 표본 마지막 줄 `as of 12:43 AM,`의 쉼표는 형식 일부가 아니라 표본과 지시문을 잇는 문장 부호였다. 출력에 쉼표를 넣지 않는다.

17. **기억 on/off 설정 없음:** 제품 설정(`settings.json` 계약)에 기억 기능 토글이 없어, 기억 금지는 설정이 아니라 전역 지침 문장으로만 강제한다.
