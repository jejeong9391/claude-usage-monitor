# Multi AI Usage Monitor 구현 플랜

## 목표

현재 Claude Code 중심 메뉴바 앱을 여러 AI 플랫폼의 사용량 허브로 확장한다.

- 설정에서 메뉴바에 메인으로 표시할 AI를 선택한다.
- 메뉴바 클릭 시 메인 AI뿐 아니라 연결된 모든 AI의 사용량/상태를 한 화면에서 본다.
- 공급자별 공식 집계 가능 범위가 다르므로, 단일 퍼센트로 억지 통합하지 않는다.
- 각 수치마다 출처와 신뢰도를 명확히 표시한다.

## 공식 집계 전략

### Claude

- 개인 Claude Code 현황: 현재 구현처럼 Claude Code Keychain OAuth 토큰으로 `api.anthropic.com/api/oauth/usage` 호출.
- 로컬 상세: `ccusage --offline`로 비용/토큰/burn rate를 참고값으로 병합.
- 조직 공식 API: Anthropic Admin API의 Usage and Cost API 및 Claude Code Analytics API.
- 표시 원칙:
  - 5시간/주간 quota 퍼센트와 reset은 개인 메뉴바의 1순위.
  - 비용/토큰은 `ccusage`일 경우 `Local Estimate`, Admin API일 경우 `Official Admin`으로 구분.

### OpenAI / Codex

- OpenAI API 사용량: OpenAI Usage API / Cost API를 사용한다.
- Codex 제품 사용량:
  - 공식 quota 화면은 Codex TUI `/usage`와 `/status`에 있다.
  - 메뉴바 앱은 `~/.codex/sessions/**/*.jsonl`의 `token_count.rate_limits` 이벤트를 읽어 5시간/주간 사용률, reset, 오늘 token usage를 집계한다.
  - `~/.codex/state_5.sqlite`의 `threads.tokens_used`는 보조 모델/source 요약에만 사용한다.
  - 공개 문서 기준 개인 ChatGPT/Codex quota를 외부 앱에서 직접 읽는 안정 REST API는 확인되지 않았다.
  - Enterprise Analytics API는 workspace 관리자용 일/주 버킷 집계로 사용할 수 있지만, 개인 실시간 5시간 세션 reset 대체재는 아니다.
  - 오픈소스 조사 결과 `codex-usage-tracker`, `usage`, `aiusage`, `tokscale`, `AgentLimits` 등이 있으며, 신뢰 가능한 로컬 방식은 Codex session JSONL의 `token_count`/`rate_limits` 파싱이다.
- 표시 원칙:
  - OpenAI API 사용량과 Codex 제품 사용량을 분리한다.
  - Codex는 5시간 사용률을 primary로 표시하고 주간 사용률, reset, 오늘 input/output/cache/reasoning token을 상세에 표시한다.
  - Codex session 로그의 `rate_limits`는 Codex가 로컬에 남긴 서비스 스냅샷이므로 `Local Session` 출처로 표시하되, 공식 공개 API 호출로 오해시키지 않는다.

### Cursor

- 팀/조직 공식 API: Cursor Admin API, Analytics API, AI Code Tracking API.
- 주요 수치: request 수, token usage, charged cents, model, accepted lines, AI code tracking.
- 표시 원칙:
  - 팀 API key가 있는 경우 `Official Admin`.
  - 로컬 Cursor 사용량은 `state.vscdb`의 `composerData`와 대화 header 수를 읽어 `Local Estimate`로 표시한다.
  - 개인 계정 token/cost quota API가 없는 경우 token/cost는 표시하지 않는다.

## 공통 데이터 모델

앱 내부에서는 모든 공급자를 다음 스냅샷으로 정규화한다.

```swift
struct ProviderSnapshot {
    let provider: AIProviderKind
    let title: String
    let sourceKind: UsageSourceKind
    let confidence: UsageConfidence
    let state: ProviderState
    let period: UsagePeriod
    let primary: UsageMetric
    let resetAt: Date?
    let costUSD: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let requestCount: Int?
    let modelSummary: String?
    let updatedAt: Date?
}
```

중요한 원칙:

- `primary`는 provider마다 다를 수 있다. Claude는 percent, OpenAI는 cost/tokens, Cursor는 requests/cost가 자연스럽다.
- provider별 원본 모델은 보존한다. 정규화 과정에서 잃는 정보가 있으면 상세 카드에 표시하지 않는다.
- 수치가 없으면 0으로 보이지 않는다. 반드시 `연결 필요`, `공식 API 없음`, `권한 필요`, `오프라인` 등 상태로 표시한다.

## UX 설계

### 2026-07-01 UI 재설계 반영

초기 1차 구현은 메인 카드, 전체 AI 목록, 기존 Claude 상세가 한 화면에 중복되어 정보 위계가 약했다.
수정 방향은 다음과 같다.

- 한 화면에는 선택된 AI의 상세만 표시한다.
- Claude는 이전처럼 5시간 세션, 주간/모델 한도, ccusage 비용·토큰 상세를 한 흐름에서 본다.
- OpenAI API, Codex, Cursor는 상단 provider 탭으로 전환한다. 이 탭은 상세 화면에서 보는 AI만 바꾸며 메뉴바 기본 AI는 바꾸지 않는다.
- 전체 AI 목록 카드는 제거한다. 연결 상태는 provider 탭의 작은 상태 점과 각 provider 화면의 상태 카드로만 표시한다.
- 사용량/설정 세그먼트는 노출하지 않는다. 우측 상단 톱니바퀴만 설정 진입점으로 둔다.
- 설정 화면에서는 우측 상단에 텍스트가 포함된 `사용량` 버튼을 보여 명확히 돌아갈 수 있게 한다.
- 설정 화면에서 메뉴바 기본 AI를 선택한다. 이 값이 메뉴바 타이틀의 유일한 기준이다.
- 설정 화면은 메뉴바 기본 AI 선택 + 설정 대상 AI 탭 + 선택된 AI 설정으로 구성한다. 모든 AI 설정을 세로로 나열하지 않는다.
- 설정은 provider별 계정 모델이 다르므로 공통 폼 하나로 합치지 않는다.
  - Claude: Claude Code OAuth Keychain 상태 + 선택적 Anthropic Admin key.
  - OpenAI API: Admin API key, Organization ID, Project ID.
  - Codex: 사용자가 계정 정보를 다시 입력하지 않는다. `~/.codex/auth.json` 또는 `codex login status`로 로컬 세션을 자동 감지하고, 공식 개인 usage API 미확인 상태는 별도로 표현한다.
  - Cursor: 로컬 composer DB 기반 추정 사용량 + Team API key, Team/Workspace 식별자.
- API key는 UserDefaults에 저장하지 않고 macOS Keychain에만 저장한다.
- Organization ID, Project ID, Team ID처럼 비밀이 아닌 범위 설정만 UserDefaults에 저장한다.
- 로그인/로그아웃 제어 범위:
  - Claude Code 개인 계정: 공식적으로 `claude` 실행 후 브라우저 로그인, CLI 내부 `/logout`으로 처리한다. 앱에서 임의로 세션을 삭제하지 않는다.
  - Anthropic/OpenAI/Cursor Admin 계정: API key 저장이 로그인, Keychain 삭제가 로그아웃이다.
  - Codex CLI: `codex login`/`codex logout` 하위 명령이 있으며, 앱에서는 로컬 세션 감지와 Codex 웹/앱 진입, CLI logout 실행까지만 연결한다.
- 로컬 세션에서 감지한 토큰 값은 앱 상태에 저장하거나 UI에 표시하지 않는다. 표시 대상은 로그인 방식, 계정 ID, credential 위치, 마지막 갱신 시각 같은 메타데이터로 제한한다.
- Codex는 예외적으로 session JSONL에 기록된 `token_count.rate_limits`와 `last_token_usage`를 사용량 화면에 표시한다. 이 값은 사용자의 credential/token 원문이 아니라 Codex가 남긴 사용량 카운터다.
- 앱 실행, 활성화, 메뉴바 팝오버 열기, 수동 새로고침 시 로컬 세션을 자동 재감지한다.
- 자동 감지 범위:
  - Claude: Claude Code macOS Keychain OAuth 또는 앱에 저장된 Anthropic Admin key.
  - OpenAI API: 앱 Keychain Admin key, `OPENAI_ADMIN_KEY`, `OPENAI_API_KEY` 같은 프로세스 환경변수.
  - Codex: `~/.codex/auth.json` 또는 `codex login status`.
  - Cursor: 앱 설치/로컬 데이터 존재, 앱 Keychain Cursor Team API key.
- 로컬 사용량 집계 범위:
  - Codex: `sessions/**/*.jsonl`의 `token_count.rate_limits`, `last_token_usage`, `model_context_window`; `state_5.sqlite`의 model/source는 보조 요약.
  - Cursor: `state.vscdb`의 `composerData` count, conversation header count.
- 브라우저 쿠키, 앱 내부 private token처럼 공식 사용량 API 연결에 필요 없고 깨지기 쉬운 자격증명은 읽지 않는다.

### 메뉴바

설정된 `primaryProvider`의 `menuBarTitle`만 표시한다.

예시:

- Claude: `🔥 58% · 2h41m`
- OpenAI API: `OpenAI $3.42`
- Cursor: `Cursor 185 req`
- 연결 불가: `OpenAI 연결`

합산 메뉴바 표시는 2차 기능으로 둔다. 비용 합산은 가능하지만 quota 퍼센트 합산은 의미가 약하다.

### 팝오버

상단:

- 앱 제목: `AI Usage`
- 보조 문구: 선택된 메인 provider와 마지막 갱신
- 새로고침 버튼

본문:

- `Main` 카드: 현재 선택된 provider의 주요 수치.
- `All Providers` 목록: Claude, OpenAI API, Codex, Cursor.
- 각 provider row/card는 상태 배지를 가진다.
  - `Official`
  - `Admin`
  - `Local`
  - `Setup`
  - `Unavailable`

하단:

- 메인 AI 선택 picker.
- 업데이트/종료 버튼.

### 설정

1차 구현에서는 앱 내부 설정만 지원한다.

- 메인 AI 선택: Claude, OpenAI API, Codex, Cursor.
- provider enable/disable.

2차 구현에서 credential 입력/저장을 붙인다.

- macOS Keychain 저장.
- API key 유효성 검사.
- 권한 부족/403/429/네트워크 실패를 provider별로 분리.

## 구현 단계

### 1단계: 다중 provider 골격과 UI 전환

- `UsageStore`를 multi-provider snapshot을 발행하도록 확장한다.
- 기존 Claude 공식 + ccusage 동작을 그대로 `Claude` snapshot으로 매핑한다.
- OpenAI API는 아직 실제 호출하지 않고 `setupRequired` 또는 `configured` snapshot으로 표시한다.
- Codex와 Cursor는 로컬 DB가 있으면 `Local Estimate` snapshot으로 표시한다.
- 설정에서 메인 provider를 선택하고 UserDefaults에 저장한다.
- 메뉴바 타이틀은 선택된 provider snapshot에서 계산한다.
- 기존 Claude 카드 상세는 유지하되, 메인/목록 구조에 편입한다.

### 2단계: OpenAI API provider

- Keychain에서 OpenAI Admin key를 읽는다.
- `/v1/organization/usage/completions`, `/v1/organization/costs`를 호출한다.
- 오늘/주간 비용, 토큰, 모델 breakdown을 표시한다.
- Admin key가 없거나 권한 부족이면 명확한 setup/error 상태를 표시한다.

### 3단계: Cursor provider

- Cursor team API key를 Keychain에서 읽는다.
- Admin/Analytics API로 request, charged cents, token usage, model summary를 가져온다.
- 개인 Cursor 계정만 있는 경우 로컬 composer DB 기반 request 추정치를 표시하고 token/cost는 비워 둔다.

### 4단계: Anthropic Admin provider

- 조직 API key가 있으면 Claude API usage/cost와 Claude Code Analytics를 공식 Admin 출처로 표시한다.
- 개인 OAuth provider와 Admin provider가 동시에 있을 때 충돌하지 않도록 별도 카드로 표시하거나 출처 우선순위를 설정한다.

## 리스크와 방지책

- 단위 혼합: percent, requests, tokens, cost를 하나의 숫자로 합산하지 않는다.
- 공식성 오해: 모든 카드에 출처 배지를 표시한다.
- credential 저장: API key는 UserDefaults에 저장하지 않는다. 2단계부터 Keychain 사용.
- 개인/조직 혼동: OpenAI API 사용량과 Codex 제품 사용량을 분리한다.
- rate limit: provider별 상태로 격리하고, 한 provider 실패가 전체 UI를 망가뜨리지 않게 한다.
- 기존 기능 회귀: Claude 메뉴바 표시와 팝오버 상세는 1단계에서 반드시 유지한다.
- 네트워크 부하: 기본 polling은 60초 유지, Admin API는 더 긴 주기 또는 수동 갱신 옵션 검토.

## 검증 계획

- `./build.sh --no-install`로 컴파일 검증.
- Claude 기존 메뉴바 문자열이 기존 정상 상태에서 동일하게 나오는지 확인.
- UserDefaults 메인 provider 변경 후 메뉴바 문자열이 선택에 따라 바뀌는지 확인.
- provider 설정/미설정 상태에서 UI가 0값처럼 오해되지 않는지 확인.
- no token, unauthorized, rate limit, offline 상태가 provider별로 분리되는지 확인.
