---
name: github-push-auth-context
description: agent-scripts에서 사용자가 요청한 GitHub 푸시가 HTTPS 인증 오류로 실패했을 때, 이 저장소에서 확인한 Git 인증 도우미와 gh 계정 선택 맥락을 적용합니다.
---

# GitHub 푸시 인증 맥락

확인일: 2026-11-15. 이 저장소를 푸시하며 확인한 로컬 인증 관측 3개입니다. 원격 URL, 계정 선택, 로그인 상태는 달라질 수 있으므로 해당 오류를 해결할 때 현재 설정을 확인해 주세요.

1. **fetch 성공과 push 인증 실패가 함께 발생:** 원격이 `https://github.com/velar-agent/agent-scripts`인 상태에서 `git fetch origin`은 성공했지만, 일반 `git push origin main`은 `could not read Password for 'https://velar-agent@github.com': Device not configured`로 실패했습니다. 당시 Git 인증 도우미에는 `osxkeychain`과 `store`가 설정되어 있었습니다. 이 환경에서는 fetch 성공만으로 쓰기 인증이 준비됐다고 판단할 수 없었습니다.

2. **저장된 계정을 명시한 GitHub CLI 인증으로 해결:** `gh auth status`에는 활성 계정 `xiote-dev`와 비활성 계정 `velar-agent`가 모두 키링에 로그인된 상태로 나왔습니다. 저장소 소유자인 `velar-agent`의 토큰을 `gh auth token --hostname github.com --user velar-agent`로 캡처하고, 푸시 자식 프로세스의 `GH_TOKEN`으로 전달했습니다. 그 Git 호출에만 `credential.helper=`와 `credential.helper=!gh auth git-credential`을 지정하자 푸시가 성공했습니다. 토큰은 화면·명령 인자·파일에 출력하지 않았고, 전역 계정 전환이나 Git 설정 변경도 필요하지 않았습니다. 다른 계정이나 원격에도 이 선택을 고정하지 말고 현재 대상과 저장된 로그인을 확인해 주세요.

3. **SSH 대안은 인증 단계까지 검증하지 못함:** `BatchMode=yes`, `StrictHostKeyChecking=yes`로 GitHub SSH 접속을 확인했지만, 알려진 ED25519 호스트 키가 없어 호스트 확인 단계에서 실패했습니다. 따라서 이 작업에서 SSH 키의 유효성이나 저장소 쓰기 권한은 확인하지 못했습니다. 이후 푸시는 위 GitHub CLI의 HTTPS 인증으로 완료됐습니다.
