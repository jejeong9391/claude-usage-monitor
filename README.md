<h1 align="center">Claude Usage Monitor</h1>

<p align="center">
  macOS 메뉴바에서 <b>Claude 사용량</b>을 실시간으로 보여주는 가벼운 네이티브 앱
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift%20%2B%20SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift + SwiftUI">
  <img src="https://img.shields.io/badge/deps-none-2ea44f" alt="No dependencies">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT">
</p>

<p align="center">
  <img src="docs/preview.png" alt="드롭다운 미리보기" width="380">
</p>

<p align="center">
  <code>🔥 58% · 2h41m</code>&nbsp;&nbsp;—&nbsp;&nbsp;현재 5시간 세션 사용률 · 재설정까지 남은 시간
</p>

---

## ⚡ 무엇을 하나

| | |
|---|---|
| 📊 **공식 사용률** | Claude Code가 Keychain에 저장한 OAuth 토큰으로 `api.anthropic.com` 5시간·주간 한도를 직접 조회 |
| 💰 **비용·토큰 상세** | [`ccusage`](https://github.com/ryoppippi/ccusage) 로컬 데이터로 비용·토큰·burn rate 병합 |
| 🧩 **멀티 AI** | Claude 외 Codex·Cursor·Gemini·OpenAI 사용량도 탭으로 함께 |
| 🪶 **가벼움** | Electron/Node 없는 단일 네이티브 바이너리(~2.3MB) · 60초 자동 갱신 · Dock 아이콘 없음 |

---

## ✅ 필요 조건

| | |
|---|---|
| 💻 **macOS** | 13.0 (Ventura) 이상 · Apple Silicon |
| 🔑 **[Claude Code](https://claude.com/claude-code)** | **설치 + 로그인 필수** — 사용량을 여기서 읽습니다 |
| 🛠 **Command Line Tools** | `swiftc` 컴파일용 (아래 1단계에서 설치) |
| 📦 **[ccusage](https://github.com/ryoppippi/ccusage)** | 선택 — 없으면 사용률(%)만, 있으면 비용·토큰까지 |

---

## 🚀 설치

### 1. 도구 준비 *(한 번만)*

```bash
xcode-select --install      # 이미 설치돼 있으면 그대로 넘어갑니다
```

### 2. 내려받아 설치

```bash
git clone https://github.com/jejeong9391/claude-usage-monitor.git
cd claude-usage-monitor
./build.sh
```

> `~/Applications/ClaudeUsageMonitor.app` 에 자동 설치됩니다.

### 3. 처음 열기 &nbsp;·&nbsp; ⚠️ 이 단계가 중요

1. **Finder → `~/Applications` → `ClaudeUsageMonitor` 우클릭 → 열기 → 열기**
   <br><sub>("확인되지 않은 개발자" 경고를 통과하는 방법. **최초 1회만** 필요합니다.)</sub>
2. **Keychain 접근 프롬프트 → `항상 허용`**
   <br><sub>토큰을 읽기 위한 것으로, 값은 외부로 나가지 않습니다.</sub>

✅ 메뉴바에 **🔥 아이콘**이 나타나면 끝.

---

## 🖥 메뉴바에 보이는 것

| 표시 | 의미 |
|---|---|
| `🔥 58% · 2h41m` | 정상 — 사용률 · 재설정까지 남은 시간 |
| `🔒 로그인 필요` | Claude Code에 로그인하세요 |
| `호출 제한` | 일시적 rate limit — 자동으로 복구됩니다 |
| `재인증 필요` | 토큰 만료 — Claude Code 재로그인 |
| `오프라인` | 네트워크 또는 API 응답 확인 필요 |

---

## 🔄 부팅 시 자동 시작 *(선택)*

`시스템 설정 → 일반 → 로그인 항목` 에 `ClaudeUsageMonitor` 추가

---

<details>
<summary><b>📤 다른 Mac에 전달하기 (.dmg)</b></summary>

<br>

```bash
./build.sh --dmg     # dist/ClaudeUsageMonitor.dmg 생성
```

받는 사람은 위 **3. 처음 열기** 단계(우클릭 → 열기 → 열기)와 동일하게 열면 됩니다.
경고 없이 배포하려면 Apple Developer Program($99/년)의 Developer ID 서명 + notarization이 필요합니다.

</details>

<details>
<summary><b>🧩 Intel Mac</b></summary>

<br>

현재 `ccusage` 경로(`/opt/homebrew/bin`)와 빌드 타깃이 Apple Silicon 기준입니다.
Intel에서는 `src/Providers.swift` 의 경로와 빌드 아키텍처 조정이 필요합니다.

</details>

<details>
<summary><b>🗂 코드 구조 · 설계 문서</b></summary>

<br>

```
src/
├── main.swift          앱 진입점 · NSStatusItem · 팝오버 · 폴링 타이머
├── Models.swift        공식/ccusage 응답 모델 · 포맷 헬퍼
├── Providers.swift     Keychain 토큰 · 공식 usage API · ccusage 호출 · 응답 분류
├── ProxyStatus.swift   시스템/환경변수 프록시 감지
├── DiagnosticLog.swift 로컬 진단 로그(회전 파일)
├── Telemetry.swift     익명 진단 이벤트
├── Store.swift         결과 병합 · 메뉴바 타이틀 계산
├── Views.swift         SwiftUI 드롭다운 UI
└── Theme.swift         색상 · 타이포
build.sh                컴파일 → .app 번들 → ad-hoc 서명 → (옵션) .dmg
```

설계·계획 문서: [`docs/superpowers/`](docs/superpowers/)

</details>

---

## 🔒 개인정보

| 데이터 | 처리 |
|---|---|
| **토큰** | 로컬 Keychain에서만 읽어 Anthropic 공식 API 호출에 사용 · **외부 전송/저장 없음** |
| **ccusage** | 로컬에서만 읽음 (`--offline`) |
| **익명 진단** *(기본 on · 끌 수 있음)* | 결과 분류·HTTP 상태/오류 코드·프록시 사용 여부·앱/OS 버전·익명 설치 ID만 익명 집계 · **토큰·사용량·계정 정보는 전송 안 함** |
| **로컬 진단 로그** *(기본 off)* | 켤 때만 `~/Library/Logs/ClaudeUsageMonitor/`에 로컬 저장(≤512KB) · 외부 전송 없음 |

진단 항목은 `설정 → 진단`에서 켜고 끌 수 있습니다.

---

<p align="center"><sub><a href="LICENSE">MIT</a></sub></p>
