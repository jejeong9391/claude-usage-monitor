# ClaudeUsageMonitor — "갑자기 안 됨" 진단 런북

작성: 2026-07-13 · 대상 repo: `/Users/jeongjieun/PhpstormProjects/claude-usage-monitor`

---

## 0. ▶ 확정 관찰: "Claude CLI는 되는데, 앱은 '네트워크 연결 안됨'"

상대가 본 문구는 `Store.swift:601`의 **`.offline` 상태 메시지**다:
> "네트워크 연결 또는 Anthropic 사용량 API 응답을 확인하세요."

그리고 `.offline`은 순수 "네트워크 다운"이 아니라 **"네트워크/기타 실패"**(`Providers.swift:56`) — 즉 아래 전부가 이 한 메시지로 뭉뚱그려진다:
`response==nil`(TLS/연결 실패) · 2xx아닌 상태(403/407/500/502) · 200인데 본문이 에러객체 · 200인데 디코드 실패.

**CLI가 동시에 잘 된다 = 인터넷·api.anthropic.com 도달성·OAuth 인증 모두 정상.** (아니면 CLI도 죽는다.
또 토큰을 못 읽으면 `.noToken`("로그인 필요")이 떠야 하는데 `.offline`이 뜬다 → **토큰은 읽히고 요청은 나갔다.**)
그런데도 앱만 실패 → **원인은 "앱과 CLI의 네트워크 접근 방식 차이"**다.

### 결정적 기술 차이
| | Claude CLI (Node/curl 계열) | 네이티브 앱 (`URLSession.shared`) |
|---|---|---|
| 프록시 소스 | `HTTPS_PROXY`/`https_proxy` **환경변수** + 시스템 설정 | **System Settings → Network → Proxies 만.** 셸 환경변수 무시 |
| base URL | `ANTHROPIC_BASE_URL` 존중(게이트웨이로 우회 가능) | `api.anthropic.com` **하드코딩**(`Providers.swift:60`), `ANTHROPIC_BASE_URL` 무시 |

→ **가장 유력한 근본원인:** 그 사람 환경에 **환경변수/게이트웨이 기반 프록시**(`HTTPS_PROXY` 또는 `ANTHROPIC_BASE_URL`)가 있고,
직접 egress(api.anthropic.com 직결)는 막혀 있다. CLI는 프록시로 나가 성공, 앱은 그 프록시를 못 보고 직결 시도 → 실패 → `.offline`.
(대안: 시스템 설정에 **TLS 가로채기 프록시**가 있어 앱의 인증서 검증만 실패하고, CLI는 `NODE_EXTRA_CA_CERTS` 등으로 그 CA를 신뢰.)

### 결정적 테스트 (상대 맥, 3분)
```bash
# 1) 프록시가 어디에 설정돼 있나
env | grep -iE 'proxy|anthropic'          # 환경변수 프록시 / ANTHROPIC_BASE_URL
scutil --proxy                            # 시스템 설정 프록시
cat ~/.claude/settings.json 2>/dev/null   # env.ANTHROPIC_BASE_URL / HTTPS_PROXY 지정 여부

TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')

# 2) 앱처럼 '직결'(환경변수 프록시 무시)  vs  CLI처럼 '프록시 경유'
curl -sS --noproxy '*' -m 15 -o /dev/null -w 'DIRECT       : %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage
curl -sS            -m 15 -o /dev/null -w 'VIA-ENV-PROXY: %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage
```

### 판정표
| DIRECT | VIA-ENV-PROXY | 결론 & 조치 |
|---|---|---|
| 실패(000/timeout/SSL) | **200** | **확정: 환경변수 프록시라 앱이 못 씀.** → 같은 프록시를 **System Settings → Network → Proxies**에 등록(그래야 URLSession이 사용). TLS 가로채기면 프록시 root CA를 **시스템 키체인에 신뢰**로 추가 |
| 실패(SSL certificate) | 실패/200 | **TLS 가로채기.** → 프록시 CA를 시스템 키체인에 신뢰 추가 |
| **200** | 200 | 앱이 직결 가능한데도 `.offline` → 프록시 아님. **엔드포인트/응답 파싱 문제**(§6-3, 버전 드리프트). curl 본문(`-o /dev/null` 빼고)으로 `{"error":...}`인지 확인 |
| 실패 | 실패(그래도 CLI는 됨) | CLI가 api.anthropic.com 직결이 아님 → `ANTHROPIC_BASE_URL` 게이트웨이 경유. `~/.claude/settings.json` 확인. 앱은 이 우회를 못 함(하드코딩) → **앱 구조상 지원 안 됨** |

> **참고:** 네(작성자) 맥에서는 앱이 잘 뜬다면, 이건 API/버전 문제가 아니라 **그 사람 네트워크 환경 문제**라는 강한 방증이다. 환경변수/시스템설정 프록시부터 본다.

### ✅ 스크린샷으로 확정된 사실 (2026-07-13)
- 화면 문구/아이콘 `"공식 데이터 오프라인" · "네트워크 연결을 확인하세요." · wifi.slash` = **`origin/main`(653d692, 2026-06-25)의 `Views.swift:68`과 정확히 일치.**
  → **상대는 GitHub에 올라간 2026-06-25 빌드를 쓰는 중.**
- 그 6/25 빌드도 엔드포인트·헤더(`/api/oauth/usage`, `oauth-2025-04-20`)와 `OfficialUsage` **응답 모델이 최신본과 동일** → 코드/버전이 원인이 아님. **환경(네트워크) 문제로 확정 좁혀짐.**
- 앱은 정상 실행(드롭다운 렌더링) → 서명/Gatekeeper/실행 문제 아님. **official 네트워크 fetch만 실패**.

### ⚠️ 구버전(6/25)의 함정: "네트워크 연결 확인"은 실제 네트워크가 아닐 수 있다
`Providers.swift` diff 기준, 6/25 버전 fetch 로직은 **401만 "재인증"으로 걸러내고 나머지를 전부 `.offline`으로 뭉뚱그린다**:
- **429(rate limit)** → 6/25 버전은 디코드 실패 → **`.offline`("네트워크 연결 확인")로 오표기.** (최신본은 `"호출 제한"`으로 구분)
- 비2xx(403/407/5xx)·응답 본문 이상 → 전부 `.offline`.

→ 저 메시지를 곧이곧대로 "네트워크 다운"으로 믿으면 안 된다. **실제로는 rate-limit이거나 프록시 차단일 수 있다.** §0 결정 테스트의 `curl` HTTP 코드로 진짜 원인을 확인할 것(200/429/403/407/000 각각 의미가 다름).

**권장 다음 액션 2가지 (병행):**
1. §0의 `curl` 2줄(DIRECT / VIA-ENV-PROXY) 실행 → 프록시냐 rate-limit이냐 즉시 판정.
2. 어차피 구버전이니 **최신 `.app` 빌드를 전달**하면 (a) 에러 메시지가 정확해지고(호출제한/재인증/오프라인 구분) (b) rate-limit이었다면 자동복구, (c) 프록시면 여전히 offline이라 원인이 더 또렷해진다.

---

## 1. 현재 Git 상태 (요약)

| 항목 | 값 |
|------|-----|
| 실제 repo | `/Users/jeongjieun/PhpstormProjects/claude-usage-monitor` (설치된 `.app` 번들 자체는 repo 아님. `Info.plist`의 `SourceRoot`가 여기를 가리킴) |
| 현재 브랜치 | `main` |
| 원격 대비 | **`origin/main`보다 8커밋 앞섬 (아직 push 안 됨)** |
| 미커밋 변경 | `src/Models.swift`, `src/Store.swift`, `src/Views.swift` (커밋 안 된 로컬 수정 존재) |
| remote | `https://github.com/jejeong9391/claude-usage-monitor.git` (개인 계정) |
| 기타 로컬 브랜치 | `feat/hybrid-official-usage`, `feature/in-app-update` |

## 2. 가장 최근에 push된 것

- **커밋 `653d692`** — `chore: 공유용 빌드 스크립트·README·라이선스 추가`
- **일시: 2026-06-25 00:12 KST** · author: jeongjieun
- GitHub(`origin/main`)에 올라간 최신본은 여기까지. 그 이후 8커밋(2026-06-26 ~ 07-10)은 **전부 로컬에만 있음.**

**push 안 된 8커밋(=GitHub에는 없는 기능):**
```
6a5e91a 2026-07-10  ✨ Improve multi-AI CLI usage monitoring
5612f24 2026-07-02  📝 Document multi-AI usage strategy
564bbee 2026-07-02  ✨ Add multi-AI local session monitoring
3afdb25 2026-06-29  docs: 운영 런북(operations.md) 추가
458cff5 2026-06-28  feat: 자체 서명 인증서 서명 + ad-hoc 폴백
8671056 2026-06-27  fix: 로딩/rate-limit 상태 구분 + security 타임아웃
2360058 2026-06-26  feat: 인앱 업데이트 버튼 (git pull→재빌드→재시작)
6c736d6 2026-06-26  docs: 인앱 업데이트·재시작 설계 문서
```

> ⚠️ **결정적 포인트:** 상대방이 GitHub에서 `git clone`/`pull` 했다면 **2026-06-25 버전**을 쓰는 것이다.
> 네 로컬 07-10 빌드와 **전혀 다른(구) 버전**이며 multi-AI·인앱업데이트·자체서명 폴백이 없다.
> → "상대방이 정확히 무엇을 받았는가"부터 확정해야 진단이 산으로 안 간다:
> - (A) GitHub repo를 직접 빌드 → 구버전(2026-06-25)
> - (B) 네가 만든 `.app` 바이너리(07-10 빌드)를 그대로 전달받음 → 최신 기능 포함

---

## 3. "프록시 켜면 안 될 수 있나?" → **그렇다. 단, '일부'만 죽는다.**

### 왜 그런가 (코드 근거)
Claude 사용량(%)은 `Providers.swift`에서 이렇게 가져온다:

- `URLSession.shared.dataTask` → `https://api.anthropic.com/api/oauth/usage` 호출 (`Providers.swift:60,74`)
- **`URLSession.shared`는 macOS 시스템 프록시 설정을 자동으로 따른다.** (System Settings → Network → Proxies, 또는 `HTTPS_PROXY`). 앱이 따로 설정하지 않아도 상속됨.
- 완료 핸들러가 **에러를 버린다**: `{ data, response, _ in }` — 세 번째 인자(error)를 `_`로 무시 (`Providers.swift:74`). 실패하면 `response == nil` → `.offline`로만 처리 (`Providers.swift:76~78`).

### 프록시 ON일 때 실제 증상
| 프록시 종류 | 결과 |
|------|------|
| HTTPS 가로채기(Charles / Proxyman / mitmproxy / 회사 MITM) | 프록시가 자기 인증서를 제시 → 앱 기본 TLS 검증 실패 → 요청 실패 → **메뉴바에 %가 안 뜨고 조용히 `offline`** (에러 팝업 없음) |
| api.anthropic.com 차단/도달불가 프록시 | 동일 → `.offline` |
| 인증 요구 프록시(407) | 2xx 아님 → `.offline` |
| 토큰 만료(401) — 프록시 무관 | `.unauthorized` → 재로그인 필요 |

### ⚠️ 중요한 구분선
프록시는 **앱 전체를 죽이지 않는다.** 아래는 네트워크를 안 타므로 프록시와 무관하게 계속 동작:
- Keychain 토큰 읽기(`security` CLI, `Providers.swift:9~33`)
- 로컬 provider들: ccusage `--offline`, Codex JSONL, Cursor DB

→ **"%만 안 뜬다 / offline 표시"** = 프록시 가설과 일치.
→ **"메뉴바 아이콘 자체가 안 뜬다 / 실행이 안 된다"** = 프록시 아님. **Gatekeeper/quarantine/서명/크래시** 쪽.

---

## 4. 증상부터 특정하기 (상대방에게 물어볼 것)

"안 된다"의 의미를 먼저 4갈래로 좁힌다:

1. **메뉴바 아이콘이 아예 안 보임** → 실행 실패. 서명/Gatekeeper/크래시 (→ §5-D)
2. **아이콘은 뜨는데 `🔒 로그인` 표시** → Keychain 토큰 없음. Claude Code 미로그인, 또는 재서명 불일치로 Keychain 접근 거부 (→ §5-C)
3. **아이콘은 뜨는데 `offline` / `—` / % 안 뜸** → 네트워크·프록시·토큰만료(401) (→ §5-A, §5-B)
4. **일부 숫자(비용·토큰)만 안 뜸** → ccusage 미설치/경로 문제(`/opt/homebrew/bin/ccusage`), 앱 자체는 정상

---

## 5. 진단 명령 (상대방 맥에서 실행)

### A. 프록시가 원인인지 결정적으로 확인 — 앱과 똑같은 호출 재현
```bash
# 시스템 프록시 상태 먼저 보기
scutil --proxy

# 앱이 하는 요청 그대로 재현 (Claude Code 로그인돼 있어야 함)
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')

curl -sS -w '\n--- HTTP %{http_code} ---\n' \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" \
  https://api.anthropic.com/api/oauth/usage
```
- **프록시 ON에서 실패(SSL certificate problem / 407 / timeout) + OFF에서 `HTTP 200` → 프록시가 원인 확정.**
- `HTTP 401` 나오면 → 토큰 만료. 프록시 아님. Claude Code 재로그인.
- `curl`은 `HTTPS_PROXY` 환경변수와 시스템 프록시를 타므로, 여기서 `SSL certificate problem`이 뜬다면 그게 바로 `URLSession`이 죽는 이유다.

### B. 프록시 우회로 즉시 복구되는지 확인
```bash
# 시스템 프록시를 끈 상태로 curl (특정 프록시만 무시)
curl -sS --noproxy '*' -w '\n--- HTTP %{http_code} ---\n' \
  -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage
```
200이면 → 프록시만 끄면(또는 api.anthropic.com을 프록시 예외에 추가하면) 복구.

### C. Keychain 토큰이 읽히는지 (🔒 로그인 증상)
```bash
security find-generic-password -s "Claude Code-credentials" -w | head -c 40; echo
```
- 값이 안 나오거나 접근 거부 프롬프트 → Claude Code 재로그인, 또는 프롬프트에서 **항상 허용**.

### D. 실행 자체가 안 될 때 (아이콘 안 뜸)
```bash
# 1) 터미널에서 포그라운드 실행 → 크래시/에러 즉시 확인 (앱에 로깅은 없음)
"/Users/<상대방>/Applications/ClaudeUsageMonitor.app/Contents/MacOS/ClaudeUsageMonitor"

# 2) quarantine 제거 (다른 맥에서 처음 열 때 Gatekeeper 차단)
xattr -dr com.apple.quarantine "/Applications/Claude Usage Monitor.app"

# 3) 서명/Gatekeeper 상태
codesign -dv --verbose=4 "/Applications/Claude Usage Monitor.app" 2>&1 | head
spctl -a -vv "/Applications/Claude Usage Monitor.app"
```
- 이 앱은 **ad-hoc 서명**만 돼 있어 다른 맥에선 "확인되지 않은 개발자" 차단이 기본. Finder 우클릭→열기, 또는 위 `xattr`로 우회.

---

## 6. 예상 시나리오 우선순위

1. **아이콘은 뜨는데 % offline** → 프록시(HTTPS 가로채기) 또는 토큰 만료. §5-A로 3분 내 확정.
2. **아이콘 자체가 안 뜸** → 프록시 아님. quarantine/서명(§5-D).
3. **구버전 문제** → 상대가 GitHub(2026-06-25)를 빌드했고 그 사이 ccusage/엔드포인트 동작이 달라졌을 수 있음. 이 경우 최신본을 push하거나 07-10 `.app`을 직접 전달해야 함.
