# 진단 로깅 & 익명 텔레메트리 설계

작성: 2026-07-14 · 대상: `claude-usage-monitor` (macOS 메뉴바 앱)

## 배경 / 목적

앱을 다수 사용자에게 배포할 예정이다. 현재 공식 사용량 fetch가 실패하면 UI는
`.offline`("네트워크 연결을 확인하세요")로만 뭉개져 표시되고, **앱에 로깅이 전혀 없어**
개발자는 (a) 특정 사용자의 실패 원인을 알 수 없고 (b) 이슈가 얼마나 자주·어떤 환경에서
나는지 능동적으로 알 수 없다.

**핵심 원칙(사용자 지시): 로그·텔레메트리는 오직 이슈 분석·처리 목적이다.**
제품 분석/마케팅/사용자 행동 추적 용도로 확장하지 않는다. 필드는 진단에 필요한 최소로 제한한다.

### 목표
- 공식 fetch 실패의 **실제 원인**(네트워크/TLS/프록시/HTTP status/rate-limit/decode)을 포착한다.
- 배포 사용자 집단에서 이슈 **발생률·환경 분포**를 익명으로 집계·인지한다.
- 특정 케이스를 깊게 팔 수 있는 **전체 디테일 로컬 로그**를 남긴다.

### 비목표 (Non-goals)
- 사용량/비용/토큰 등 제품 지표 수집 ❌
- 사용자 식별·행동 퍼널·기능 사용 분석 ❌
- 크래시 스택 수집(이번 범위 아님. 필요 시 후속) ❌
- notarization/배포 서명 개선(별개 품질 항목, 후속 메모로만)

## 아키텍처: 2층 관측

```
┌─ Layer 1: 익명 텔레메트리 (능동 파악) ─────────────┐
│  Telemetry (얇은 래퍼)  ─URLSession POST─►          │
│                    TelemetryDeck/Aptabase HTTP ingest│
│   · 의존성 0 (SDK 링크 안 함, 순수 URLSession)       │
│   · 상태 전이 시에만 이벤트 1건                      │
│   · 익명 · 무PII · 진단 필드만                       │
└────────────────────────────────────────────────────┘
┌─ Layer 2: 로컬 로그 (깊은 디테일) ─────────────────┐
│  DiagnosticLog  ──►  ~/Library/Logs/.../monitor.log │
│   · 토글 on일 때만 · 256KB×2 회전                    │
│   · fetch 분류 전량 기록                             │
└────────────────────────────────────────────────────┘
         ▲ 둘 다 같은 지점에서 호출 ▲
   Store.refresh() 내 fetch 결과 처리부 (Providers.fetch → Store)
```

두 레이어는 **독립 모듈**이며 서로를 모른다. 공통 입력은 fetch 1회의 결과 + 진단 정보다.

## 공통: fetch 진단 정보 포착

현재 `OfficialUsageProvider.fetch()`는 `OfficialResult`만 반환하고, 완료 핸들러에서
**에러를 `{ data, response, _ in }`로 버린다**. 이 정보 손실을 막는 것이 설계의 알맹이다.

- `src/Providers.swift`
  - 완료 핸들러를 `{ data, response, error in }`로 바꿔 `error`를 캡처한다.
  - 신규 구조체:
    ```
    struct OfficialFetchDiagnostics {
        var httpStatus: Int?        // 있으면
        var urlErrorCode: Int?      // response==nil일 때 URLError.code.rawValue (-1200=TLS, -1009=offline, -1001=timeout)
        var urlErrorDesc: String?   // localizedDescription (짧게)
        var decodeFailed: Bool      // 200이나 디코드 실패
        var bodyWasErrorObject: Bool// 200+{"error":...}
    }
    struct OfficialFetchOutcome { let result: OfficialResult; let diagnostics: OfficialFetchDiagnostics }
    ```
  - `fetch()`는 `OfficialFetchOutcome`을 반환한다. (호출부는 `outcome.result` 사용)
- 프록시 상태는 fetch 시점에 별도 헬퍼로 수집(민감정보 아님, bool만):
  - `proxySystem: Bool` — `CFNetworkCopySystemProxySettings()`에 HTTP/HTTPS/SOCKS proxy 활성 여부
  - `proxyEnv: Bool` — `ProcessInfo.environment`에 `HTTPS_PROXY`/`https_proxy`/`ALL_PROXY` 존재 여부
  - 신규 `src/ProxyStatus.swift` (단일 함수). **주의:** URLSession은 시스템 프록시만 따르므로 `proxyEnv=true & proxySystem=false`가 이번 이슈의 시그니처다.

## 호출 지점 (정확 위치)

`src/Store.swift`의 `refresh(forceOfficial:)`(현재 107행) → `Task.detached`(117행) 내부:
1. `let outcome = OfficialUsageProvider.fetch()` (기존 118행의 `off` 대체)
2. 결과를 메인 액터에 적용하는 곳에서:
   - **직전 상태 비교**: 기존 `@Published var officialState`(24행)가 직전 결과 → `outcome.result`와 카테고리가 다르면 "전이"로 판단.
   - `Telemetry.trackOfficialResult(outcome, proxy:, previous: officialState, isFirstOfSession:)` — 전이 또는 세션 최초일 때만 내부에서 전송.
   - `DiagnosticLog.logOfficialFetch(outcome, proxy:)` — 토글 on이면 항상 1줄 기록(전이와 무관).
3. `updateOfficialCooldown(after: outcome.result)` (기존 167행) 그대로.

`isFirstOfSession`은 Store에 `private var didEmitSessionState = false` 플래그로 관리.

## Layer 1 — 익명 텔레메트리

### 빌드 제약 (설계 결정의 근거)
이 repo는 **SPM을 쓰지 않는다.** `build.sh`가 `swiftc -O src/*.swift`로 직접 컴파일하고
`Package.swift`가 없다. 게다가 인앱 업데이트가 `git pull → build.sh 재빌드` 흐름이라,
Swift Package 의존성을 추가하려면 전체를 SPM으로 전환해야 하고(빌드·서명·업데이트 전부 파급),
`swift build`의 의존성 fetch가 같은 프록시 환경에서 또 실패할 수 있다.
→ **SDK를 링크하지 않는다. 전송은 순수 `URLSession` POST로 한다.**

### 전송 방식 (의존성 0)
- `src/Telemetry.swift` 래퍼가 텔레메트리 공급자의 **HTTP ingest API로 JSON을 직접 POST**한다.
  - 1순위: **TelemetryDeck ingest** 또는 **Aptabase REST ingest** (호스팅 대시보드·알림 활용, 무료 티어).
  - 대안: 데이터 소유 원하면 동일 POST를 **자체 최소 엔드포인트**(Cloudflare Worker/서버리스 등)로. 래퍼 뒤라 대상 URL만 교체.
- 익명 installID는 **우리가 생성**해 UserDefaults에 저장(랜덤 UUID, 최초 1회). PII 아님.
- 정확한 ingest 엔드포인트·payload 스키마는 구현 계획 단계에서 context7/공식 문서로 확정한다.
- 실패는 조용히 무시(재시도 안 함, 또는 다음 전이 때 자연 재시도). 앱 동작 무영향.

### 이벤트 (단 하나)
- 이름: `official_fetch_result`
- 필드(전부 비민감):
  | 필드 | 예 | 비고 |
  |---|---|---|
  | `result` | `offline` | ok/loading/noToken/unauthorized/rateLimited/offline |
  | `httpStatus` | `407` | 없으면 생략 |
  | `urlErrorCode` | `-1200` | response==nil일 때만 |
  | `proxySystem` | `false` | bool |
  | `proxyEnv` | `true` | bool |
  | `decodeFailed` | `false` | bool |
  | (appVersion, osVersion, 익명 installID) | — | SDK 자동 |
- **토큰·자격증명·사용량 수치·경로·사용자 식별정보는 절대 포함하지 않는다.**

### 전송 정책 (볼륨·비용 최소화)
- 60초 폴링마다 보내지 않는다.
- **상태 전이 시 1건** (예: ok→offline, offline→ok) + **세션당 최초 상태 1건**.
- 결과적으로 사용자당 하루 수 건 수준. 정상 사용자는 세션당 1건(ok)만.

### 동의 정책
- **기본 on(opt-out)**, 최초 실행 시 명확 고지, 설정에서 즉시 opt-out 가능.
- 근거: 관측 목적 달성을 위해 데이터가 실제로 모여야 함. 단 수집 범위가 익명·진단 최소이므로 프라이버시 위험이 낮음.
- **README 개인정보 섹션 갱신 필수** — "익명 진단 이벤트를 보낼 수 있으며 토큰/사용량 내용은 전송하지 않음, 설정에서 끌 수 있음"을 명시.
- (검토 시 opt-in으로 전환 가능 — 그 경우 데이터량 급감 트레이드오프.)
- UserDefaults 키 `telemetryEnabled`, 기본 `true`.

## Layer 2 — 로컬 진단 로그

### 위치·회전
- `~/Library/Logs/ClaudeUsageMonitor/monitor.log`
- 크기 상한 256KB. 초과 시 `monitor.log.1`로 rename(기존 .1 덮어씀) 후 새로 시작 → **최대 2파일 ≈ 512KB 고정.**
- `~/Library/Logs`는 표준 위치라 Console.app 자동 노출 + Finder로 사용자가 압축 전송 용이.

### 토글
- UserDefaults 키 `diagnosticLoggingEnabled`, **기본 `false`**.
- off면 파일 핸들도 열지 않고 즉시 return → 오버헤드 0.
- 설정에 스위치 + "로그 폴더 열기" 버튼(`NSWorkspace.open`).

### 기록 내용 (한 줄 = fetch 1회)
```
2026-07-14T14:54:09+09:00 result=offline http=nil urlerr=-1200(SSL) proxySystem=false proxyEnv=true decodeFailed=false v=1.0 os=15.5
```
- 토큰 값은 절대 기록하지 않음. 필요 시 "토큰 존재=true/false"만.

### 모듈
- `src/DiagnosticLog.swift` — `enum DiagnosticLog { static func logOfficialFetch(_:proxy:) }`
  - enabled 확인 → 디렉토리 보장 → append → 크기 초과 시 회전.
  - **스레드 안전**: 전용 serial `DispatchQueue`로 직렬화(fetch는 백그라운드에서 호출됨).
  - 모든 파일 I/O는 `try?`로 감싸 실패해도 앱 동작에 영향 없음.

## 설정 UI

기존 설정 시트 패턴(`@Published` + `defaults.set(_:forKey:)`)을 따라 "진단" 섹션 추가:
- Toggle: **익명 사용 진단 보내기** (`telemetryEnabled`, 기본 on) — 하단에 "토큰/사용량 내용은 보내지 않습니다" 안내
- Toggle: **로컬 진단 로그 기록** (`diagnosticLoggingEnabled`, 기본 off)
- Button: **로그 폴더 열기**

## 에러 처리 / 실패 격리

- 텔레메트리 전송 실패(오프라인 등)는 조용히 무시 — 앱·UI 무영향. SDK가 자체 큐잉하면 그대로 둠.
- 로컬 로그 I/O 실패는 `try?`로 무시.
- 프록시가 egress를 막으면 텔레메트리도 안 갈 수 있음(엔드포인트는 api.anthropic.com과 다르므로 대개 도달). → 로컬 로그가 fallback.

## 테스트

- 이 repo는 테스트 프레임워크가 없고 `build.sh` 단일 컴파일 구조다.
- 최소 검증:
  - 회전 로직: cap을 임시로 작게 설정해 256KB 초과 시 `.1` 생성·2파일 상한 유지를 수동 확인.
  - 전이 감지: 임의로 official 결과를 강제(디버그 빌드)해 ok→offline 시 텔레메트리 1건, 반복 offline은 추가 전송 없음 확인.
  - 프록시 상태 헬퍼: 시스템 프록시 on/off, `HTTPS_PROXY` env 설정/해제 조합에서 bool이 맞게 나오는지 확인.
- 여력 되면 회전·전이 로직을 순수 함수로 분리해 경량 XCTest 타깃 추가(선택).

## 파일 요약

| 파일 | 변경 |
|---|---|
| `src/Providers.swift` | error 캡처, `OfficialFetchDiagnostics`/`OfficialFetchOutcome` 추가, `fetch()` 반환형 변경 |
| `src/ProxyStatus.swift` | 신규. 프록시 상태 bool 수집 |
| `src/Telemetry.swift` | 신규. HTTP ingest POST 래퍼(URLSession) + `trackOfficialResult` + 익명 installID |
| `src/DiagnosticLog.swift` | 신규. 파일 로거 + 회전 |
| `src/Store.swift` | fetch 호출부에서 두 레이어 호출, 전이/세션 플래그, 토글 UserDefaults |
| `src/Views.swift` | 설정 "진단" 섹션 토글 2개 + 폴더 열기 버튼 |
| `README.md` | 개인정보 섹션에 익명 진단 고지 |
| `build.sh`/`Package.swift` | **변경 없음.** 새 파일은 `src/*.swift`라 자동 포함. SPM 도입 안 함 |

## 후속 메모 (범위 밖)
- ad-hoc 서명 → 다수 배포 시 Gatekeeper 마찰. notarization($99/년) 별도 검토.
- 크래시 리포팅이 필요해지면 Sentry를 같은 `Telemetry` 래퍼 뒤에 병행 가능.
