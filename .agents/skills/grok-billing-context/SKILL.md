---
name: grok-billing-context
description: agent-scripts의 Grok 청구 사용량 스크립트(grok-billing.sh)를 수정하거나 그 인증·엔드포인트·요약 형식에 관한 문의에 답할 때, 사용자 요청 배경과 코드에 드러나지 않는 전제를 적용합니다.
---

# Grok 청구 사용량 조회 맥락

확인일: 2026-11-09. 이 프로젝트 작업에서 확인한 대화 맥락과 외부 전제 19개를 기록합니다. 티어 표시 표와 요약 한 줄의 구현은 `grok-billing.sh`에 있으므로 여기 다시 적지 않습니다.

1. **처음 요청:** 사용자는 경로와 출력 형식을 정하지 않고 grok-usage 스크립트만 요청했다. 같은 저장소의 `claude-usage.sh`, `codex-account-rateLimits-read.py`에 맞춰 셸 스크립트, 기본 JSON, `--summary`, `--timeout` 기본 20초, 영문 CLI, 한국어 주석으로 시작했다.

2. **이름:** 사용자는 파일명을 `grok-billing.sh`로 바꾸라고 했다. 그 시점의 저장소에는 이전 이름을 참조하는 다른 파일이 없었다.

3. **요약 형식은 사용자 지정:** `Weekly limit (X Premium+), 7%, Resets: November 10, 15:42`를 사용자가 직접 지정했다. 형식을 바꿀 때는 이 한 줄을 요구사항으로 취급한다. 7%는 형식 표본이다. 그 변경 직후 실제 사용률은 8%였다.

4. **`grok usage`는 이 한도를 대신하지 못한다:** grok 1.0.77의 셸 라우트에서 세션 ID 없이 `grok usage`를 실행하면 stderr에 `` Error: `grok usage` can't show your plan's usage here yet. Run /usage inside grok instead. ``를 출력하고 종료 코드 1이며 계정을 읽지 않는다. 사용자 가이드는 데몬 라우트에서만 백그라운드 서비스로 이 한도를 읽는다고 한다. 확인 당시 `~/.grok/leader.sock`과 `leader.sock.daemon`은 없었고 `grok leader list`는 백그라운드 서비스가 없다고 했다. grok TUI 세션 안에서 호출해도 셸 라우트였다.

5. **엔드포인트 검증:** `/billing?format=credits`가 사용량 화면의 호출이라는 근거는 grok 1.0.77 바이너리(`~/.grok/downloads/grok-macos-aarch64`)의 그 문자열과, Bearer 토큰으로 받은 200이다. Bearer 없이 토큰만 보내면 401 `Invalid or expired credentials (auth_kind=other, x_xai_token_auth=none, upstream=Unauthenticated, reason=no auth context)`이다. `/v1`이 빠진 `https://cli-chat-proxy.grok.com/billing?format=credits`는 403 `error code: 1010`이다. `x-grok-client-version`, `x-grok-client-mode`, `x-grok-client-identifier`가 없어도 Bearer만으로 200이었다. 모드 값과 문서의 기본 헤더 이름 `xai-grok-cli`는 이 호출에서 확인하지 못했다.

6. **`format=credits`가 없는 `/billing`:** 이 경로는 달력 월의 `monthlyLimit`, `used`, `history`를 반환한다. 사용량 화면의 주간 구독 풀이 아니다. 2026-11-09에 200으로 확인했다.

7. **자동 충전:** `/auto-topup-rule`은 바이너리에 있는 경로이고, 규칙이 없으면 200 `{}`였다. 사용량 모달 문구에는 Auto topup이 있다. 스크립트는 이 경로를 호출하지 않는다.

8. **요약이 쓰지 않는 응답 필드:** credits 본문에는 `onDemandCap`, `onDemandUsed`, `prepaidBalance`의 `val`, `productUsage`(`product`, `usagePercent`), `isUnifiedBillingUser`, `topUpMethod`(`TOP_UP_METHOD_SAVED_PAYMENT_METHOD`), `billingPeriodStart`, `billingPeriodEnd`가 있다. 확인 당시 상품은 `GrokBuild` 하나였고 그 사용률은 `creditUsagePercent`와 같았다. `val`의 화폐 단위는 0이 아닌 표본이 없어 정하지 못했다. `productUsage`, `usagePercent`, `TOP_UP_METHOD` 문자열은 바이너리에 없다.

9. **로그는 원시 응답이 아니다:** `~/.grok/logs/unified.jsonl`의 `billing: fetched credits config`는 `historyLen`과 `onDemandEnabled`, 표시용 `subscriptionTier`를 포함하고 `productUsage`와 `topUpMethod`는 없다. 1.0.70과 1.0.77 로그가 이 모양이다.

10. **요금제 코드와 표시 이름:** 이 계정의 `/user?include=subscription` 값은 `XPremiumPlus`이고, grok 로그의 표시 이름은 `X Premium+`이다. 바이너리에는 `X Premium+`와 `Premium`이 없다. 스네이크 케이스 열거는 `supergrok`, `x_basic`, `x_premium`, `x_premium_plus`, `supergrok_heavy`, `supergrok_lite`, `supergrok_plus`, `proxy-managed`이고, 마케팅 문구로 `SuperGrok Plus`, `SuperGrok Heavy`, `X Basic`이 있다. 스크립트 표에서 실응답으로 확인한 항목은 `XPremiumPlus`뿐이다. `SuperGrokPlus`를 `SuperGrok Plus`로 둔 것은 추정이다. 사용자 응답에는 이메일, 이름, 아이디가 있으므로 그 필드를 출력에 넣지 않는다.

11. **개발자 API 한도와 구분:** 이 조회는 문서의 개발자 API 속도 제한(지출 티어별 모델 RPS·TPM)이 아니다. API 키로 이 경로를 호출해 보지 않았다. 문서상 API 키는 세션 토큰이 없을 때의 폴백이다. API 키로 이 구독 한도를 볼 수 있다고 안내하지 않는다.

12. **인증 저장 형태와 확인하지 않은 갱신:** auth.json의 최상위 키는 `issuer::client_id`이고, `key`는 JWT이며 `auth_mode`는 `oidc`, 발급자는 `https://auth.x.ai`이다. 2026-11-09T04:50:18Z에 `expires_at`은 2026-11-09T10:39:15Z로 아직 유효했다. 사용자 가이드는 grok이 액세스 토큰을 백그라운드에서 갱신한다고 한다. 이 엔드포인트에서 refresh가 되는지, `grok login` 없이 grok만 실행해도 갱신되는지는 확인하지 않았다. 401 안내는 바이너리 문구 `Run grok login`을 따른 것이다.

13. **화면 문구와 폐기한 첫 요약:** 바이너리의 사용량 모달 문구는 Weekly limit, Monthly limit, Next reset, Pay-as-you-go, Credits, Auto topup이다. 실제 화면은 보지 않았다. 사용자가 한 줄을 지정하기 전의 요약은 `Weekly limit: N% used`와 `Next reset: Nov 10 at 3:42pm (Asia/Seoul)`였다.

14. **15:42의 기준:** 사용자가 적은 `November 10, 15:42`는 `2026-11-10T06:42:43.684529+00:00`을 이 기계의 Asia/Seoul로 바꾼 값이다. `/etc/localtime`은 Asia/Seoul이었다. 초 43은 분을 올리지 않는다. 예시에 연도가 없어 연도가 달라도 연도를 붙이지 않으며, 이 생략은 예시를 그대로 따른 것이고 따로 확인받지 않았다. 픽스처 `2027-01-03T00:00:00+00:00`은 `January 3, 09:00`, `2026-11-10T15:00:00+00:00`은 `November 11, 00:00`이었다.

15. **사용률의 방향:** `creditUsagePercent`는 사용할수록 오르는 사용률이고 남은 비율이 아니다. 모달의 left가 남은 비율인지는 화면으로 확인하지 않았다.

16. **월간 라벨은 실계정으로 보지 못했다:** `USAGE_PERIOD_TYPE_WEEKLY`는 실제 응답이다. Monthly limit은 바이너리 문구에 맞춘 이름이고, 월간 계정 응답은 받지 못했다. `USAGE_PERIOD_TYPE_MONTHLY`는 픽스처로만 시험했다.

17. **계정 맥락:** 확인 당시 계정은 personal이고 `isUnifiedBillingUser`가 true였다. 팀 배포가 사용량을 따로 재는 경로는 만나지 못했다. 다른 요금제에서는 기간과 상품 구성이 달라질 수 있다.

18. **스크립트 위치:** 사용자가 경로를 지정하지 않아 스크립트는 저장소 루트에 두었다.

19. **python3:** 옆 스크립트와 의존성을 맞추려고 python3를 골랐다. jq로 이 응답을 처리하는지는 시험하지 않았다.

코드와 주석에서 바로 알 수 있어 기록하지 않은 사실 6개: 호출 주소·Bearer·auth.json의 `key`·`GROK_HOME`·`GROK_CLI_CHAT_PROXY_BASE_URL`, 토큰 미갱신과 401일 때 `grok login` 안내, 요약 한 줄의 토큰 배치·기간 라벨·티어 표·퍼센트 끝 0 제거·현지 `Month D, HH:MM`, 요약에서만 사용자 정보를 조회하고 JSON 출력은 청구 본문만 찍는 것, 사용률이 없을 때 상품이 하나면 `usagePercent`를 쓰는 것, `--timeout` 기본 20초와 curl 28 처리.
