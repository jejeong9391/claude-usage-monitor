# Claude Usage Monitor — 설계 문서

**작성일:** 2026-06-08
**상태:** 설계 승인됨 (구현 플랜 대기)

## 1. 목적

macOS 메뉴바에 Claude Code 사용량을 **공식 데이터 기준으로 정확하게** 표시하는 네이티브 앱.
기존 `SessionMonitor.app`은 `ccusage`(로컬 로그 휴리스틱)에만 의존해 공식 페이지와
퍼센트·재설정 시각이 어긋났다. 본 앱은 Anthropic 공식 엔드포인트를 진실의 원천으로 삼아
이 불일치를 제거한다.

## 2. 핵심 발견 (검증 완료)

Claude Code는 `/usage` 표시에 다음 엔드포인트를 호출한다 (바이너리 문자열 분석 + 실제 호출로 확인):

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

**실측 응답 (2026-06-08):**

```json
{
  "five_hour":  { "utilization": 1.0,  "resets_at": "2026-06-08T10:30:00.976658+00:00" },
  "seven_day":  { "utilization": 23.0, "resets_at": "2026-06-10T02:00:00.976676+00:00" },
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization": 0.0, "resets_at": "2026-06-10T01:59:59.976683+00:00" },
  "seven_day_oauth_apps": null,
  "seven_day_cowork": null,
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null,
                   "utilization": null, "currency": null, "disabled_reason": null }
}
```

- `utilization`은 **0–100 퍼센트** 값 (이미 % 단위, 추가 보정 불필요).
- `resets_at`은 ISO8601 UTC 타임스탬프 → 실제 서버 윈도우 재설정 시각.
- `seven_day` 23%는 Claude 공식 화면의 주간 22~23%와, `seven_day_sonnet` 0%는 "Sonnet 전용 0%"와,
  `seven_day.resets_at`(2026-06-10T02:00Z = 수 11:00 KST)은 "(수) 오전 11:00 재설정"과 일치 확인.

**자격증명 위치:** macOS Keychain, 항목명 `Claude Code-credentials` (genp).
JSON 페이로드의 `claudeAiOauth.accessToken` 사용. `security find-generic-password -s "Claude Code-credentials" -w`로 추출 가능.

## 3. 아키텍처

단일 메뉴바 앱(NSStatusItem)이 60초 타이머로 **독립된 두 Provider**를 호출해 병합 표시.

```
ClaudeUsageMonitor (NSStatusItem, Timer 60s)
├── OfficialUsageProvider   ─ GET /api/oauth/usage + Keychain 토큰  → %·재설정시각 (진실)
└── CCUsageProvider          ─ Process: ccusage blocks/daily --json → 비용·토큰·burn (상세)
```

### 컴포넌트 책임

| 컴포넌트 | 한 일 | 사용법 | 의존 |
|---|---|---|---|
| `OfficialUsageProvider` | 공식 엔드포인트 호출, 응답 디코드 | `fetch() -> OfficialUsage?` | Keychain 토큰, 네트워크 |
| `CCUsageProvider` | `ccusage` 서브프로세스 실행/파싱 | `fetch() -> CCUsageDetail?` | `/opt/homebrew/bin/ccusage` |
| `KeychainToken` | `security` CLI로 accessToken 조달 | `read() -> String?` | `/usr/bin/security` |
| `StatusController` | 두 결과 병합, NSStatusItem·메뉴 갱신 | 타이머 콜백 | 위 3개 |

- 두 Provider는 서로 모른다. 한쪽 실패가 다른 쪽을 막지 않는다(**부분 실패 허용**).
- 토큰 조달은 Keychain Security API 대신 `Process`로 `security` CLI 호출 — ccusage를 부르는
  기존 패턴과 동일해 코드 최소화. 최초 1회 Keychain 접근 허용 프롬프트가 뜰 수 있음.

## 4. 화면 구성

**메뉴바(항상 표시):** `🔥 58% · 2h41m`
- `five_hour.utilization` % + `resets_at`까지 카운트다운.
- 색조는 텍스트 색상으로만 은은하게(여유=기본색, 경고/위험=강조색).

**드롭다운(클릭 시):**

| 구역 | 출처 | 내용 |
|---|---|---|
| 5h 세션 | 공식 | % 바, `resets_at`까지 카운트다운, 시작/종료 시각 |
| 주간 (모든 모델) | 공식 | `seven_day` % 바, 수 11:00 KST 리셋까지 |
| 주간 Sonnet | 공식 | `seven_day_sonnet` (null이면 숨김) |
| 주간 Opus | 공식 | `seven_day_opus` (값 있을 때만) |
| 추가 사용량 크레딧 | 공식 | `extra_usage` (`is_enabled` 시만) |
| ─ 상세 ─ | ccusage | 현재 비용 $, burn rate $/hr, 블록 종료 예측, 토큰 세부(입력/출력/캐시), 모델 목록 |
| 푸터 | — | 마지막 갱신 시각, 수동 새로고침(⌘R), 종료 |

→ 모든 %·재설정은 공식치. "추정/보정" 라벨 제거. ccusage는 "참고 상세"로 격하.

## 5. 갱신 · 에러 처리

- **폴링 60초** (두 Provider 각각). 수동 ⌘R 즉시 갱신.
- **공식 401(토큰 만료)**: 해당 구역에 "재인증 필요 — Claude Code 사용 시 자동 갱신" 표시.
- **공식 네트워크 실패**: 직전 값 유지 + "⚠ 오프라인" 표시.
- **ccusage 실패**: 상세 구역만 "—", 공식 구역은 정상.
- **토큰 미발견**: "Claude Code 로그인 필요" 안내.

## 6. 빌드 · 배포

- `swiftc -O -framework Cocoa src/main.swift -o build/ClaudeUsageMonitor`
- `.app` 번들 구성(`Info.plist` `LSUIElement=true`, bundle id `com.jeongjieun.ClaudeUsageMonitor`) → `~/Applications/`.
- 로그인 항목 등록(System Events).
- 빌드 시 CLT modulemap 충돌(`module.modulemap` vs `bridging.modulemap` redefinition) 재현되면
  `sudo mv .../module.modulemap .../module.modulemap.bak` 1회 적용(즉시 복원 가능).

## 7. 명시적 비범위 (YAGNI, v1 제외)

- OAuth refresh 토큰 **자체 갱신** (Claude Code가 갱신하는 토큰을 읽기만 함).
- 알림/경고 푸시, 사용량 히스토리 그래프, 멀티 계정.

## 8. 위험 / 주의

- `/api/oauth/usage`는 **비공개 내부 엔드포인트**. Anthropic이 예고 없이 응답 형태 변경/차단 가능 →
  앱이 깨질 수 있음. 디코딩은 누락 필드에 관대하게(Optional) 구현하고, 실패 시 graceful degrade.
- 본인 토큰을 Claude Code 외부에서 사용하는 것은 ToS 회색지대(본인 데이터·읽기 전용·개인 모니터링
  용도라 위험 낮다고 판단하나 보장 불가).

## 9. 성공 기준

- 메뉴바 % 와 재설정 카운트다운이 Claude Code `/usage` 화면과 **일치**.
- 드롭다운 주간/Sonnet %·재설정이 공식 화면과 일치.
- 공식 호출 실패 시에도 ccusage 상세는 계속 표시(부분 실패 허용 동작 확인).
- 재부팅 후 로그인 항목으로 자동 실행.
