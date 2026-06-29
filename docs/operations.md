# 운영 런북 (Operations)

이 앱을 **운영(시작·종료·재시작·업데이트·진단)** 하기 위한 실전 메모. 다음에 처음부터 분석하지 않으려고 정리했다.
일반 소개·빌드·배포는 [README.md](../README.md), 코드 서명은 [code-signing.md](code-signing.md) 참고.

## TL;DR — 위치와 한 줄 명령

| 항목 | 값 |
|------|----|
| 설치본(.app) | `~/Applications/ClaudeUsageMonitor.app` |
| 소스 | `~/PhpstormProjects/claude-usage-monitor` |
| 번들 ID | `com.jeongjieun.ClaudeUsageMonitor` |
| 자동 실행 | 로그인 항목에 `ClaudeUsageMonitor` 등록됨(부팅 시 자동) |
| 빌드/설치 | `cd ~/PhpstormProjects/claude-usage-monitor && ./build.sh` |
| 데이터 갱신 | 60초 자동 폴링(메뉴바 카운트다운은 5초) |

```bash
# 실행
open ~/Applications/ClaudeUsageMonitor.app
# 종료
pkill -f "Applications/ClaudeUsageMonitor.app"
# 재시작
pkill -f "Applications/ClaudeUsageMonitor.app"; sleep 1; open ~/Applications/ClaudeUsageMonitor.app
# 실행 중인지 확인
ps aux | grep -i "Applications/ClaudeUsageMonitor.app/Contents/MacOS" | grep -v grep
```

> 메뉴바 전용 앱(`LSUIElement`)이라 Dock에 안 뜬다. GUI로 시작하려면 Launchpad/Spotlight에서 "Claude Usage Monitor" 검색 또는 Finder에서 `.app` 더블클릭. 종료는 메뉴바 아이콘 클릭 → 팝오버 우하단 **종료** 버튼.

## 메뉴바 상태 읽기 (중요)

메뉴바 타이틀은 `src/Store.swift`의 `menuBarTitle`이 결정한다. 기호별 의미와 대응:

| 표시 | 의미 | 대응 |
|------|------|------|
| `🔥 7% · 4h18m` | 정상. 현재 5시간 세션 사용률 · 재설정까지 남은 시간 | 없음 |
| `…` | 로딩 중(첫 fetch 전) 또는 일시적 무데이터 | 잠시 대기. 계속되면 아래 트러블슈팅 |
| `⏳` | **사용량 API rate limit**(429 또는 200+`rate_limit_error`). 일시적 | **기다리면 자동 복구.** 엔드포인트를 직접 반복 호출하지 말 것(악화) |
| `⚠︎` | 그 외 데이터 실패(네트워크/디코드 등) | 네트워크 확인. 토큰 만료면 Claude Code 한 번 사용 시 갱신 |
| `🔒 로그인` | Keychain에 자격증명 없음 | 터미널에서 Claude Code 로그인 |

> `⏳`와 `…`는 정상 동작이며 **고장이 아니다.** 예전엔 이 상태들이 모두 `⚠`로 보여 오해를 샀는데, 이를 구분하도록 고쳤다(`OfficialResult.loading` / `.rateLimited`).

## 인앱 업데이트

팝오버 우하단 **업데이트** 버튼 → 다음을 자동 수행:
1. 소스에서 `git pull --ff-only`(실패해도 무시)
2. 현재 워킹트리 기준 `build.sh` 재빌드 + `~/Applications` 재설치
3. 성공 시 새 버전으로 자동 재시작 / **빌드 실패 시 기존 앱 유지**(재시작 안 함, 팝오버에 실패 표시)

동작 원리:
- 앱은 소스 경로를 **Info.plist의 `SourceRoot` 키**로 안다(빌드 시 `build.sh`가 주입). 확인: `/usr/libexec/PlistBuddy -c "Print :SourceRoot" ~/Applications/ClaudeUsageMonitor.app/Contents/Info.plist`
- 빌드 로직은 전부 `build.sh`에 있음. 앱은 순서·재시작만 담당(`src/UpdateService.swift`).
- 재시작은 분리 프로세스가 1초 뒤 `open` 후 현재 인스턴스를 종료하는 방식.

> **수동 업데이트**도 동일: `cd ~/PhpstormProjects/claude-usage-monitor && ./build.sh` 후 재시작.

## 멀티 디스플레이 · 노치 동작 (알아둘 제약)

- 메뉴바 항목은 **활성(보고 있는) 디스플레이의 메뉴바를 따라다닌다.** 한쪽 모니터에 고정되지 않는다.
- **"모든 화면 동시 표시"는 불가능**하다 — 서드파티 `NSStatusItem`을 여러 디스플레이에 복제하는 macOS 공개 API가 없다(시계·와이파이만 됨).
- **노치 있는 내장 디스플레이**에서 메뉴바가 혼잡하면(다른 메뉴바 앱 多 + 포커스 앱 메뉴가 넓을 때) **가장 왼쪽 상태 항목(이 앱)이 가려질 수 있다.** macOS 한계이며 강제 표시 API 없음.
  - 완화: 타이틀 폭 줄이기(현재는 유지하기로 함) 또는 무료 메뉴바 관리자 **Ice** 병행.
  - 외장 모니터 연결 시 그쪽 메뉴바에 표시되며 가림이 사라지는 경우가 많다.

## 데이터 소스

- **공식 사용률(%·재설정)**: `https://api.anthropic.com/api/oauth/usage`. 인증은 Keychain 항목 `Claude Code-credentials`의 OAuth accessToken(`security` CLI로 읽음, `src/Providers.swift`).
- **비용·토큰·burn(참고용)**: `ccusage`(`/opt/homebrew/bin/ccusage`, `--offline`). 없으면 사용률만 표시.

## 코드 서명 (업데이트 후 keychain 재프롬프트 방지)

- 기본은 ad-hoc 서명 → 빌드마다 identity가 바뀌어 업데이트 후 keychain 접근 프롬프트가 다시 뜰 수 있다.
- **자체 서명 인증서**(`ClaudeUsageMonitor Local`)를 만들면 고정 identity로 프롬프트가 사라진다. 무료. 1회 수동 생성 필요.
- 방법·검증: [code-signing.md](code-signing.md). `build.sh`는 인증서가 있으면 자동 사용, 없으면 ad-hoc 폴백.
- 현재 서명 확인: `codesign -dvvv ~/Applications/ClaudeUsageMonitor.app 2>&1 | grep -E "Authority|Signature"` (`Signature=adhoc`이면 ad-hoc)

## 트러블슈팅 플레이북

### "메뉴바에 안 보인다"
1. 실행 여부: `ps aux | grep -i "Applications/ClaudeUsageMonitor.app/Contents/MacOS" | grep -v grep`
   - 없으면 → `open ~/Applications/ClaudeUsageMonitor.app`
2. 크래시 로그: `ls -t ~/Library/Logs/DiagnosticReports/ | grep -i ClaudeUsageMonitor | head`
3. 실행 중인데 안 보이면 → **노치 가림**(위 멀티 디스플레이 절). 외장 모니터 쪽 메뉴바 확인 또는 Ice 사용.
4. 메뉴바 스크린샷으로 확인(내장 노치 디스플레이 1728pt 폭, 노치 우측 절반):
   `screencapture -x -R 864,0,864,28 /tmp/bar.png && open /tmp/bar.png`

### "데이터가 안 나온다 / 안 돌아온다"
- 메뉴바가 `⏳` → **rate limit. 정상이며 기다리면 복구.** 엔드포인트를 수동 curl로 반복하면 악화되니 금지.
- `🔒 로그인` → Claude Code 로그인 필요.
- `⚠︎` → 네트워크/토큰. 토큰 존재 확인(값 출력 금지):
  `security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1 && echo "토큰 있음" || echo "토큰 없음"`
- (꼭 필요할 때만) 엔드포인트 상태 코드만 확인 — **과호출 주의**:
  ```bash
  T=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
  curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $T" -H "anthropic-beta: oauth-2025-04-20" --max-time 15 https://api.anthropic.com/api/oauth/usage
  # 429 = rate limit, 200 = 정상(단 본문이 {error:rate_limit_error}일 수도 있음)
  ```

### "업데이트가 실패한다"
- 팝오버에 "빌드 실패: …" 표시 → 소스 컴파일 오류. 터미널에서 직접 빌드해 메시지 확인: `cd ~/PhpstormProjects/claude-usage-monitor && ./build.sh`
- 실패해도 기존 설치본은 보존된다(재설치는 빌드 성공 후에만).

## 코드 위치 빠른 참조

| 무엇 | 파일 |
|------|------|
| 진입점·NSStatusItem·폴링·팝오버 토글 | `src/main.swift` |
| 메뉴바 타이틀(상태 기호) 계산 | `src/Store.swift` (`menuBarTitle`, `OfficialResult`) |
| Keychain 토큰·공식 API·ccusage·상태 매핑 | `src/Providers.swift` |
| 인앱 업데이트(pull→build→relaunch) | `src/UpdateService.swift` |
| 팝오버 UI(업데이트/종료 버튼 포함) | `src/Views.swift` |
| 빌드·서명·설치·SourceRoot 주입 | `build.sh` |

## 저장소 메모

- 이번 기능들은 브랜치 `feature/in-app-update`에 있음(인앱 업데이트, 상태 메시징, 자체 서명, 이 런북). 운영 반영하려면 `main` 병합 필요.
