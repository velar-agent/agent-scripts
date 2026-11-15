---
name: github-push-auth-context
description: agent-scripts에서 사용자가 요청한 커밋·GitHub 푸시가 작성자 설정 누락이나 HTTPS 인증 오류로 실패했을 때, 이 저장소에서 확인한 작성자 정보·Git 인증 도우미·gh 계정 선택 맥락을 적용합니다.
---

# GitHub 푸시 인증 맥락

확인일: 2026-11-15. 이 저장소의 커밋·푸시에서 확인한 관측 7개입니다. 1~3번은 macOS, 4~7번은 이후 Linux 환경에서의 기록입니다. 원격 URL, 계정 선택, 로그인 상태, 원격 반영 여부는 달라질 수 있으므로 해당 오류를 해결할 때 현재 설정과 상태를 확인해 주세요.

1. **fetch 성공과 push 인증 실패가 함께 발생:** 원격이 `https://github.com/velar-agent/agent-scripts`인 상태에서 `git fetch origin`은 성공했지만, 일반 `git push origin main`은 `could not read Password for 'https://velar-agent@github.com': Device not configured`로 실패했습니다. 당시 Git 인증 도우미에는 `osxkeychain`과 `store`가 설정되어 있었습니다. 이 환경에서는 fetch 성공만으로 쓰기 인증이 준비됐다고 판단할 수 없었습니다.

2. **저장된 계정을 명시한 GitHub CLI 인증으로 해결:** `gh auth status`에는 활성 계정 `xiote-dev`와 비활성 계정 `velar-agent`가 모두 키링에 로그인된 상태로 나왔습니다. 저장소 소유자인 `velar-agent`의 토큰을 `gh auth token --hostname github.com --user velar-agent`로 캡처하고, 푸시 자식 프로세스의 `GH_TOKEN`으로 전달했습니다. 그 Git 호출에만 `credential.helper=`와 `credential.helper=!gh auth git-credential`을 지정하자 푸시가 성공했습니다. 토큰은 화면·명령 인자·파일에 출력하지 않았고, 전역 계정 전환이나 Git 설정 변경도 필요하지 않았습니다. 다른 계정이나 원격에도 이 선택을 고정하지 말고 현재 대상과 저장된 로그인을 확인해 주세요.

3. **SSH 대안은 인증 단계까지 검증하지 못함:** `BatchMode=yes`, `StrictHostKeyChecking=yes`로 GitHub SSH 접속을 확인했지만, 알려진 ED25519 호스트 키가 없어 호스트 확인 단계에서 실패했습니다. 따라서 이 작업에서 SSH 키의 유효성이나 저장소 쓰기 권한은 확인하지 못했습니다. 이후 푸시는 위 GitHub CLI의 HTTPS 인증으로 완료됐습니다.

4. **Linux의 Git 작성자 설정 누락:** Linux 환경에서 최초 커밋은 `Author identity unknown`으로 실패했습니다. 기존 커밋들의 작성자·커미터가 `velar-agent <343875130+velar-agent@users.noreply.github.com>`로 일치함을 확인한 뒤, 해당 커밋 명령에만 `-c user.name=velar-agent`와 `-c user.email=343875130+velar-agent@users.noreply.github.com`을 지정해 성공했습니다. 전역 설정이나 저장소 설정을 변경하지 않았으며, 이 작성자 정보를 다른 저장소의 기본값으로 확대하지 않습니다.

5. **Linux에서는 macOS의 인증 상태를 재사용할 수 없었음:** 당시 `gh auth status`는 로그인된 GitHub 호스트가 없다고 반환했고, Git 인증 도우미와 `GH_TOKEN`·`GITHUB_TOKEN` 등 관련 토큰 환경변수도 없었습니다. `git push origin main`은 `could not read Username for 'https://github.com': No such device or address`로 실패했습니다. 2번의 macOS 계정 선택 방식은 저장된 로그인이 있던 환경의 해결책이며, 이 Linux 환경에서 성공한 방식으로 기록하지 않습니다.

6. **커밋 생성·푸시 실패·후속 원격 확인의 구분:** Linux 추출기 추가 커밋 `3d32f8f`는 로컬 `main`에 생성됐지만, 해당 작업의 푸시 시도는 5번의 인증 오류로 실패했습니다. 이후 이 스킬을 기록할 때 `git ls-remote origin refs/heads/main`으로 같은 커밋이 원격 `main`에 반영되어 있음을 확인했습니다. 후속 푸시의 실행 주체와 인증 경로는 확인하지 않았으므로, 원격 반영 사실을 앞선 인증 문제를 해결한 절차의 근거로 사용하지 않습니다.

7. **GitHub 플러그인 확인 범위:** 푸시 인증 실패 후 GitHub 플러그인을 검색했을 때 제공 가능한 플러그인으로 나왔지만 미설치 상태였습니다. 설치·연결을 제안했으며, 해당 작업에서는 연결 완료나 플러그인을 통한 쓰기 인증을 확인하지 못했습니다. 플러그인 발견·제안을 실제 연결이나 Git CLI 인증 성공으로 간주하지 않습니다.
