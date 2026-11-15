# Grok Bot Cursor 토큰의 Windows 추출 구현 안내

확인일: 2026-11-15

Windows에서 로그인된 Grok Bot의 활성 계정 액세스 토큰을 읽어 표준 출력으로 반환하는 스크립트를 구현하기 위한 인계 자료입니다. macOS에서는 토큰 추출과 사용량 API의 HTTP 200 응답을 확인했습니다. Windows의 실제 파일, 복호화, API 인증은 아직 검증하지 않았으므로 아래의 예상 경로와 Electron 구현을 대상 PC에서 확인해 주세요.

## 구현할 동작과 사용자 요구사항

- 성공하면 **액세스 토큰 한 줄만** 표준 출력으로 반환하고 종료 코드 0을 사용해 주세요. 사용자는 `echo`로 토큰을 출력하는 방식을 요청했습니다. PowerShell이나 Python을 선택해도 같은 출력 규약을 지켜 주세요.
- `Bearer ` 접두사, 환경변수 대입문, JSON, 성공 안내문은 토큰 출력에 붙이지 마세요. 오류는 영어로 표준 오류에 출력하고 0이 아닌 종료 코드를 사용해 주세요.
- 활성 계정만 선택해 주세요. 로그인한 계정을 찾을 수 없을 때 다른 저장 계정이나 오래된 최상위 토큰으로 대체하지 마세요.
- 저장된 토큰과 암호화 키를 읽기만 해 주세요. 자동 로그인, refresh token 교환, 키 재생성, 인증 파일 수정, `.env` 자동 저장은 구현 범위에 포함하지 않습니다.
- 코드의 오류 문자열과 콘솔 메시지는 영어로 작성해 주세요. 코드 주석과 docstring은 영어 설명을 먼저 쓰고 한국어 설명을 뒤에 병기해 주세요.

Windows 파일명과 구현 언어는 아직 정하지 않았습니다. PowerShell로 작성한다면 `grok-bot-cursor-token-from-windows-dpapi.ps1` 같은 이름을 사용할 수 있습니다. 기존 macOS 파일명은 사용자가 선택한 이름이므로 유지해 주세요.

## 먼저 읽을 저장소 파일

| 파일 | 참고할 내용 |
| --- | --- |
| [macOS 토큰 추출 스크립트](../grok-bot-cursor-token-from-macos-keychain.sh) | 활성 계정 선택, 저장 형식, stdout 및 stderr 규약 |
| [Grok Bot 사용량 조회 스크립트](../grok-bot-cursor-usage.sh) | 환경변수 인증, API 요청, 응답 처리 |
| [.env.example](../.env.example) | `GROK_BOT_ACCESS_TOKEN` 설정과 환경변수 실행 예제 |
| [.gitignore](../.gitignore) | `.env` 및 `.env.*` 제외, `.env.example` 유지 |

사용량 스크립트는 `-h`, `--summary`, `--env-file`을 지원합니다. 사용자가 `--timeout` 옵션을 제거하도록 요청했으며 현재 HTTP 요청 제한 시간은 20초로 고정되어 있습니다. macOS 추출기의 `--timeout`은 키체인 접근용으로 별개이며 기본값은 60초입니다.

## macOS에서 확인한 인증 구조

기준 설치본은 Grok Bot **1.1.0**이며, 포함된 Electron Framework의 `CFBundleVersion`은 **43.8.9**입니다. Windows 설치본의 버전도 같다고 가정하지 말고 별도로 확인해 주세요.

macOS 저장 파일은 `~/Library/Application Support/Grok Bot/sand-secrets.json`입니다. 설치본의 `Contents/Resources/app.asar` 안에서 `dist/electron-main/main-core.cjs`가 저장소 처리와 `safeStorage.decryptString` 호출을 포함합니다. `main.cjs`에는 `userData`와 `sessionData` 경로 설정도 있습니다. 번들 파일명과 축약된 함수명은 업데이트로 바뀔 수 있으므로 `sand-secrets.json`, `cursor-accounts`, `cursor-access-token`, `safeStorage`, `userData` 문자열을 기준으로 찾아 주세요.

저장소의 현재 구조를 나타내는 예제입니다. 계정명과 암호문은 모두 자리표시자입니다.

```json
{
  "version": 1,
  "cursor-accounts": "{\"active\":\"example-account\",\"accounts\":{\"example-account\":{\"cursor-access-token\":\"<base64 ciphertext>\"}}}"
}
```

`cursor-accounts`는 객체가 아닌 **JSON 문자열**입니다. 외부 파일을 JSON으로 읽고, 이 문자열을 다시 JSON으로 파싱한 뒤 `accounts[active]["cursor-access-token"]`을 선택합니다. `cursor-refresh-token`과 계정 프로필도 저장될 수 있지만 추출 대상은 액세스 토큰뿐입니다.

현 macOS 스크립트는 다음 형식도 처리합니다. Windows에서 같은 형식을 지원할지는 설치본의 코드와 표본을 확인해 주세요.

| 형식 | 현재 처리 |
| --- | --- |
| 최상위 `cursor-access-token` | `cursor-accounts` 항목이 없는 이전 저장소에서 사용합니다. |
| `scoped:v1:<64자리 소문자 hex>:<암호문 base64>` | 바깥쪽 계정 범위 접두사를 검증하고 제거합니다. |
| `plaintext:v1:<base64>` | 명시적인 평문 저장 형식을 디코딩합니다. 복호화 실패를 이 형식으로 간주하지 않습니다. |
| 일반 base64 문자열 | 디코딩한 바이트를 운영체제에 맞는 복호화 함수에 전달합니다. |

실계정에서 확인한 macOS 암호문은 base64 디코딩 후 `v10`으로 시작했습니다. 복호화에는 키체인 서비스 `Grok Bot Safe Storage`, 계정 `Grok Bot Key`의 값과 PBKDF2-SHA1/AES-128-CBC를 사용합니다. 세부 상수는 macOS 스크립트를 참고해 주세요. **macOS의 `v10` 복호화 함수를 Windows에 그대로 옮기면 안 됩니다.**

## Windows에서 확인할 파일과 실행 환경

Grok Bot 공식 설치 안내에는 Windows x64와 Arm64 지원이 명시되어 있습니다. 먼저 대상 PC에 앱을 설치하고, 토큰을 추출할 계정으로 로그인해 주세요. [Grok Bot 설치 안내](https://docs.x.ai/grok-bot/get-started)

우선 조사할 경로는 다음과 같습니다. 이는 Electron의 기본 경로 규칙과 macOS에서 확인한 앱 이름으로 추정한 **후보 경로**입니다.

| 용도 | Windows 후보 경로 |
| --- | --- |
| 로그인 정보 | `%APPDATA%\Grok Bot\sand-secrets.json` |
| 암호화 키 설정 | `%APPDATA%\Grok Bot\Local State` |

Electron은 기본적으로 Windows의 `%APPDATA%`와 앱 이름으로 `userData`를 구성합니다. 앱이 경로를 변경했거나 별도 프로필을 사용하면 위치가 달라집니다. 대상 앱의 `app.getPath("userData")`, `app.getPath("sessionData")`, `app.setPath` 사용을 확인하고, 다른 프로필의 두 파일을 섞어 읽지 마세요. Electron 43.8.9는 `sessionData`의 `Local State`를 읽습니다. [Electron 경로 규칙](https://www.electronjs.org/docs/latest/api/app#appgetpathname), [43.8.9의 Local State 처리](https://github.com/electron/electron/blob/v43.8.9/shell/browser/browser_process_impl.cc)

경로가 다를 때 명시적으로 지정할 수 있도록 인증 파일과 `Local State` 경로 옵션을 제공하는 편이 좋습니다. 저장소 버전, 실제 Electron 버전, 암호문 접두사도 확인해 주세요. 진단에는 경로, 버전, 필드 존재 여부, 길이 정도만 사용하고 실제 토큰이나 암호화 키 전체는 기록하지 마세요.

복호화는 Grok Bot에 로그인한 **동일한 Windows 사용자와 PC의 사용자 프로필**에서 실행하는 것을 기준으로 구현해 주세요. DPAPI는 일반적으로 같은 로그온 자격 증명과 컴퓨터를 요구합니다. 관리자 권한으로 실행하는 것이 다른 사용자 프로필의 복호화를 대신하지 않습니다. [Microsoft CryptUnprotectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptunprotectdata)

Windows 네이티브 프로세스에서 DPAPI를 호출해 주세요. WSL의 Linux Python에서 Windows 복호화 API를 바로 호출할 수 있다고 가정하지 마세요. 기존 사용량 조회 파일도 Bash 스크립트이므로 Windows에서 호출하려면 Bash, `python3`, `curl` 실행 환경을 별도로 확인해야 합니다.

## Windows 복호화 구현의 근거와 절차

Electron 공식 문서는 Windows `safeStorage`가 DPAPI로 보호되는 키를 사용한다고 설명합니다. 설치된 Grok Bot이 동기 `decryptString`을 쓰는지, 비동기 `decryptStringAsync`를 쓰는지도 확인해 주세요. [Electron safeStorage](https://www.electronjs.org/docs/latest/api/safe-storage)

현재 기준 설치본과 같은 Electron **43.8.9**의 동기 API는 `OSCrypt::DecryptString`을 호출합니다. 이 버전은 Chromium에서 제거된 동기 백엔드를 패치로 복원하므로 Chromium의 최신 소스만 찾아서는 구현이 보이지 않을 수 있습니다. 아래 절차의 기준은 해당 태그의 Windows 구현입니다. [43.8.9 safeStorage 구현](https://github.com/electron/electron/blob/v43.8.9/shell/browser/api/electron_api_safe_storage.cc), [동기 백엔드 복원 패치](https://github.com/electron/electron/blob/v43.8.9/patches/chromium/revert_oscrypt_remove_sync_backend.patch)

대상 Windows 파일이 이 구현과 일치하는 경우 다음 순서로 처리합니다.

1. `Local State` JSON의 `os_crypt.encrypted_key`를 base64 디코딩합니다.
2. 디코딩한 키 데이터의 첫 5바이트가 ASCII `DPAPI`인지 확인하고 제거합니다.
3. 나머지를 현재 사용자의 DPAPI로 복호화합니다. 이 경로의 추가 entropy는 없으며, 결과는 32바이트 AES 키입니다.
4. 활성 계정 토큰을 base64 디코딩하고 첫 3바이트 `v10`을 확인합니다.
5. 다음 12바이트를 nonce로, 나머지를 인증 태그가 포함된 암호문으로 취급합니다. 256비트 키의 AES-GCM과 빈 associated data로 복호화하고 인증 태그를 검증합니다.
6. 결과를 엄격한 UTF-8로 해석하고, 빈 값이나 줄바꿈이 없는 토큰인지 확인한 후 한 줄로 출력합니다.

위 키 및 nonce 길이, `DPAPI`와 `v10` 처리, AES-GCM 방식은 복원 패치의 `components/os_crypt/sync/os_crypt_win.cc`, `InitWithExistingKey`, `DecryptString`에 근거합니다. Windows Grok Bot의 실데이터에서는 아직 검증하지 않았습니다. DPAPI는 이 경로에서 **AES 키를 푸는 단계**이므로 `v10` 토큰 전체를 DPAPI에 바로 전달하지 마세요. 키가 없거나 복호화가 실패하면 오류로 종료하고 `Local State`에 새 키를 생성하지 마세요. [해당 Windows 구현](https://github.com/electron/electron/blob/v43.8.9/patches/chromium/revert_oscrypt_remove_sync_backend.patch)

구현 언어에 따라 다음 API를 사용할 수 있습니다.

| 작업 | 선택 가능한 API와 확인할 점 |
| --- | --- |
| DPAPI 복호화 | .NET의 `ProtectedData.Unprotect`와 `DataProtectionScope.CurrentUser`, 또는 Win32 `CryptUnprotectData`를 사용할 수 있습니다. 추가 entropy는 저장 형식에 맞춰야 합니다. |
| Python AES-GCM | `cryptography`의 `AESGCM.decrypt`는 암호문과 16바이트 태그가 이어진 데이터를 받습니다. `v10` 형식이면 nonce는 `blob[3:15]`, 태그가 포함된 데이터는 `blob[15:]`입니다. |
| .NET AES-GCM | `AesGcm.Decrypt`에는 암호문과 태그를 분리해서 전달합니다. 대상 PowerShell/.NET 런타임의 타입 및 생성자 지원을 확인해 주세요. |

각 API의 입력과 인증 실패 처리는 [ProtectedData.Unprotect](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.protecteddata.unprotect), [Python AESGCM](https://cryptography.io/en/latest/hazmat/primitives/aead/#cryptography.hazmat.primitives.ciphers.aead.AESGCM), [.NET AesGcm](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.aesgcm)을 참고해 주세요.

`v11` 등 다른 접두사, 다른 키 저장 필드, 비동기 API의 새 형식이 보이면 설치된 Electron 버전의 구현부터 확인해 주세요. 알 수 없는 형식에 임의로 CBC/GCM/DPAPI를 차례로 적용하거나, 실패한 결과를 평문 토큰으로 출력하지 마세요.

## 사용량 API와 환경변수 연동

추출 결과는 `GROK_BOT_ACCESS_TOKEN` 환경변수 값으로 사용할 수 있습니다. 이 변수가 설정되어 있으면 `.env`가 없어도 사용량 스크립트가 동작하며, `.env`와 `--env-file`의 값보다 우선합니다. 토큰은 해당 셸과 자식 프로세스에서 사용되며 자동 갱신되지 않습니다. 기존 `.env` 내용은 유지해 주세요.

현재 저장소에서 실계정 HTTP 200을 확인한 요청 규격은 다음과 같습니다.

```http
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus
Authorization: Bearer <access token>
Content-Type: application/json
Connect-Protocol-Version: 1

{}
```

이것은 Grok Bot 앱의 내부 API입니다. 공개된 안정적 API 계약으로 취급하지 마세요. 실제 요청과 오류 처리는 [사용량 스크립트](../grok-bot-cursor-usage.sh)를 기준으로 맞춰 주세요. 기존 `grok-billing.sh`의 Grok Build 인증 경로는 별도입니다.

- `usagePercent`는 사용률입니다. 예를 들어 `49.17301`은 약 49.17% 사용을 뜻하며 0과 1 사이의 비율이 아닙니다. 값이 없으면 0으로 만들어 표시하지 마세요.
- `nextResetTimestampUtc`는 UTC 초기화 시각입니다. 사람이 읽는 요약에서는 현지 시간으로 변환합니다.
- `grokPlanLabel`과 `cursorPlanName`은 서로 다를 수 있습니다. Cursor가 `Free`여도 Grok 요금제 연동으로 Bot 사용량이 반환될 수 있습니다.
- 토큰 추출 성공과 API 인증 성공은 별도로 확인해 주세요. HTTP 401이면 저장된 토큰이 만료되거나 폐기되었을 수 있습니다. 앱에서 로그인을 갱신한 뒤 다시 추출하도록 안내하고, 추출 스크립트가 refresh token을 교환하지 않도록 해 주세요.

## Windows 구현 완료 기준

| 확인 항목 | 통과 기준 |
| --- | --- |
| 실제 저장소와 버전 | Windows 앱/Electron 버전, 인증 파일 및 `Local State` 위치를 확인합니다. |
| 활성 계정 | 여러 계정이 있는 가상 저장소에서 지정된 활성 계정만 선택합니다. 활성 계정 누락 시 다른 계정 토큰을 출력하지 않습니다. |
| 정상 복호화 | DPAPI로 보호한 테스트용 AES 키와 AES-GCM 암호문으로 원래 토큰이 정확히 복원됩니다. |
| 실패 처리 | 잘못된 JSON/base64, 누락된 키, 다른 사용자 컨텍스트, 잘린 암호문, 잘못된 인증 태그, 지원하지 않는 접두사는 명확한 오류가 됩니다. |
| 출력 규약 | 성공 시 stdout은 토큰 한 줄이며, 실패 시 stdout은 비어 있고 종료 코드는 0이 아닙니다. |
| 파일 보존 | 인증 파일, `Local State`, 기존 `.env` 내용이 바뀌지 않습니다. |
| 실제 API 인증 | 대상 Windows 계정에서 추출한 토큰으로 위 사용량 API가 HTTP 200과 JSON을 반환합니다. |
| 환경변수 연동 | `.env`가 없어도 동작하고, 환경변수가 env 파일보다 우선하는 것을 확인합니다. |

테스트에는 생성한 가상 토큰과 키를 사용해 주세요. 실계정 검증 결과에는 HTTP 상태와 성공 여부를 기록하고, 토큰·refresh token·복호화 키는 테스트 출력이나 커밋에 남기지 마세요. 사용자가 직접 실행하는 추출기의 토큰 stdout 출력은 의도된 기능입니다.

완료 후 이 문서에 Windows에서 확인한 버전과 경로, 실제 형식, 구현 파일명, 검증 결과를 반영하고 `.env.example` 또는 해당 도움말에 검증된 Windows 실행 예제를 추가해 주세요. Windows에서 실행하지 못한 경우에는 구현 완료와 실계정 검증 완료를 구분해서 보고해 주세요.
