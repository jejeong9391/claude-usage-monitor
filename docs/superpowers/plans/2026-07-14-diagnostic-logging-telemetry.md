# 진단 로깅 & 익명 텔레메트리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 공식 fetch 실패의 실제 원인을 익명 텔레메트리(집계)와 로컬 로그(디테일)로 포착해, 배포 사용자 이슈를 능동적으로 분석·처리한다.

**Architecture:** 2층. (1) `Telemetry` 래퍼가 상태 전이 시 익명 진단 이벤트를 URLSession으로 HTTP ingest에 POST. (2) `DiagnosticLog`가 토글 on일 때 fetch 1회당 1줄을 회전 파일에 기록. 둘 다 `Store.refresh()`의 fetch 결과 처리부에서 호출되며, 실제 원인은 `Providers.swift`의 순수 분류 함수가 포착한다.

**Tech Stack:** Swift + AppKit/SwiftUI, raw `swiftc` 빌드(SPM 없음), 외부 의존성 0, URLSession, CFNetwork, UserDefaults.

## Global Constraints

- 빌드: `build.sh`의 `swiftc -O src/*.swift`. **SPM/외부 패키지 도입 금지.** 신규 파일은 `src/*.swift`라 자동 포함.
- 플랫폼: macOS 13+.
- **텔레메트리·로그에 토큰/자격증명/사용량 수치/경로/사용자 식별정보 절대 포함 금지.** 익명 진단 필드만.
- **목적 제한: 이슈 분석·처리 전용.** 제품 분석/행동 추적으로 확장 금지.
- 로컬 로그 기본 **off** (`diagnosticLoggingEnabled=false`), 텔레메트리 기본 **on** (`telemetryEnabled=true`, opt-out) + README 고지.
- 로그 파일 상한: **256KB × 2파일**(`monitor.log`, `monitor.log.1`).
- 텔레메트리 전송 조건: **상태 전이 시 + 세션 최초 1건**. 60초 폴링마다 보내지 않음.
- 파일 I/O·네트워크 실패는 `try?`/무시로 **앱 동작에 절대 영향 없음**.
- 테스트: 이 repo는 XCTest 타깃이 없다. **순수 함수는 `tests/*.swift`(top-level 코드로 PASS/FAIL 출력)를 관련 `src` 파일과 함께 `swiftc`로 컴파일해 실행**한다. **중요 — Swift는 여러 파일 동시 컴파일 시 top-level 문장을 `main.swift`라는 이름의 파일에서만 허용한다.** 따라서 실행 시 테스트 파일을 임시 `main.swift`로 복사해 컴파일한다:
  ```bash
  d=$(mktemp -d); cp tests/<NAME>.swift "$d/main.swift"
  swiftc "$d/main.swift" <deps...> [-framework CFNetwork] -o "$d/t" && "$d/t"
  ```
  (커밋되는 파일명은 `tests/<NAME>.swift` 그대로 두고, 복사본만 `main.swift`로 쓴다.) UI/파일 I/O는 `build.sh` 빌드 + 런타임 확인.

---

### Task 1: 프록시 상태 헬퍼

**Files:**
- Create: `src/ProxyStatus.swift`
- Create: `src/AppInfo.swift`
- Test: `tests/ProxyStatusTests.swift`

**Interfaces:**
- Produces:
  - `struct ProxyStatus { let system: Bool; let env: Bool }`
  - `func currentProxyStatus() -> ProxyStatus`
  - `func proxyEnvPresent(_ env: [String: String]) -> Bool`
  - `func proxySystemEnabled(_ settings: [String: Any]) -> Bool`
  - `func appVersionString() -> String`
  - `func osVersionString() -> String`

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/ProxyStatusTests.swift`

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// env 감지
check(proxyEnvPresent(["HTTPS_PROXY": "http://p:8080"]) == true, "env HTTPS_PROXY set")
check(proxyEnvPresent(["all_proxy": "socks://p:1080"]) == true, "env all_proxy set")
check(proxyEnvPresent(["HTTPS_PROXY": ""]) == false, "env empty string ignored")
check(proxyEnvPresent([:]) == false, "env none")

// system 감지 (CFNetwork 설정 딕셔너리 형태 모사)
check(proxySystemEnabled(["HTTPSEnable": 1]) == true, "system HTTPS on")
check(proxySystemEnabled(["SOCKSEnable": 1]) == true, "system SOCKS on")
check(proxySystemEnabled(["ProxyAutoConfigEnable": 1]) == true, "system PAC on")
check(proxySystemEnabled(["HTTPEnable": 0, "HTTPSEnable": 0]) == false, "system all off")
check(proxySystemEnabled([:]) == false, "system none")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: 테스트가 실패(컴파일 에러)하는지 확인**

Run: `swiftc tests/ProxyStatusTests.swift src/ProxyStatus.swift -o /tmp/proxytest 2>&1 | head`
Expected: `error: cannot find 'proxyEnvPresent' in scope` (src 파일이 아직 없음)

- [ ] **Step 3: 최소 구현** — `src/ProxyStatus.swift`

```swift
import Foundation

struct ProxyStatus {
    let system: Bool   // System Settings 프록시 활성 여부 — URLSession이 따르는 것
    let env: Bool      // HTTPS_PROXY 등 환경변수 존재 — CLI가 따르는 것
}

func proxyEnvPresent(_ env: [String: String]) -> Bool {
    ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"].contains { env[$0]?.isEmpty == false }
}

func proxySystemEnabled(_ settings: [String: Any]) -> Bool {
    func on(_ key: String) -> Bool { (settings[key] as? Int) == 1 }
    return on("HTTPEnable") || on("HTTPSEnable") || on("SOCKSEnable") || on("ProxyAutoConfigEnable")
}

func currentProxyStatus() -> ProxyStatus {
    let system = (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any])
        .map(proxySystemEnabled) ?? false
    return ProxyStatus(system: system, env: proxyEnvPresent(ProcessInfo.processInfo.environment))
}
```

> 컴파일 노트: `CFNetworkCopySystemProxySettings`는 CFNetwork 심볼이다. `import Foundation`으로 안 잡히면 컴파일 명령에 `-framework CFNetwork`를 추가한다. (테스트는 순수 함수만 호출하므로 심볼 링크만 필요.)

3b. 앱 버전/OS 헬퍼 — `src/AppInfo.swift` (여러 모듈이 공용으로 사용):

```swift
import Foundation

func appVersionString() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
}

func osVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swiftc tests/ProxyStatusTests.swift src/ProxyStatus.swift -framework CFNetwork -o /tmp/proxytest && /tmp/proxytest`
Expected: 마지막 줄 `ALL PASS`

- [ ] **Step 5: 커밋**

```bash
git add src/ProxyStatus.swift src/AppInfo.swift tests/ProxyStatusTests.swift
git commit -m "feat: 프록시 상태(system/env) 감지 + 앱/OS 버전 헬퍼 추가"
```

---

### Task 2: fetch 진단 포착 + 순수 분류 함수

지금 `fetch()`는 완료 핸들러에서 `error`를 버리고(`{ data, response, _ in }`) `OfficialResult`만 반환한다. 분류를 순수 함수로 분리해 실제 원인(HTTP status·URLError code·decode 실패)을 포착하고, `fetch()`는 결과+진단을 함께 반환한다.

**Files:**
- Modify: `src/Providers.swift` (`OfficialResult` enum 뒤, `OfficialUsageProvider` 내부)
- Test: `tests/ClassifierTests.swift`

**Interfaces:**
- Consumes: `OfficialResult`(기존), `OfficialUsage`(Models.swift)
- Produces:
  - `struct OfficialFetchDiagnostics { var httpStatus: Int?; var urlErrorCode: Int?; var urlErrorDesc: String?; var decodeFailed: Bool; var bodyWasErrorObject: Bool }`
  - `struct OfficialFetchOutcome { let result: OfficialResult; let diagnostics: OfficialFetchDiagnostics }`
  - `func classifyOfficialResponse(data: Data?, httpStatus: Int?, error: Error?) -> OfficialFetchOutcome`
  - `extension OfficialResult { var telemetryName: String }`
  - `static func OfficialUsageProvider.fetch() -> OfficialFetchOutcome` (반환형 변경)

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/ClassifierTests.swift`

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}
func data(_ s: String) -> Data { Data(s.utf8) }

// 1) HTTP 응답 없음 + URLError → offline + urlErrorCode 포착
let netErr = URLError(.secureConnectionFailed)
let o1 = classifyOfficialResponse(data: nil, httpStatus: nil, error: netErr)
check(o1.result.telemetryName == "offline", "no-response → offline")
check(o1.diagnostics.urlErrorCode == netErr.errorCode, "urlErrorCode captured")

// 2) 401 → unauthorized
check(classifyOfficialResponse(data: nil, httpStatus: 401, error: nil).result.telemetryName == "unauthorized", "401 → unauthorized")

// 3) 429 → rateLimited
check(classifyOfficialResponse(data: nil, httpStatus: 429, error: nil).result.telemetryName == "rateLimited", "429 → rateLimited")

// 4) 200 + rate_limit 에러 객체 → rateLimited + bodyWasErrorObject
let o4 = classifyOfficialResponse(data: data(#"{"error":{"type":"rate_limit_error"}}"#), httpStatus: 200, error: nil)
check(o4.result.telemetryName == "rateLimited", "200+rate_limit body → rateLimited")
check(o4.diagnostics.bodyWasErrorObject, "bodyWasErrorObject flagged")

// 5) 200 + 기타 에러 객체 → offline
check(classifyOfficialResponse(data: data(#"{"error":{"type":"overloaded_error"}}"#), httpStatus: 200, error: nil).result.telemetryName == "offline", "200+other error → offline")

// 6) 200 + 유효 usage → ok
let o6 = classifyOfficialResponse(data: data(#"{"five_hour":{"utilization":42.0,"resets_at":"2026-07-14T20:00:00Z"}}"#), httpStatus: 200, error: nil)
check(o6.result.telemetryName == "ok", "200+valid → ok")

// 7) 200 + 디코드 불가(JSON 배열) → offline + decodeFailed
let o7 = classifyOfficialResponse(data: data("[1,2,3]"), httpStatus: 200, error: nil)
check(o7.result.telemetryName == "offline", "200+garbage → offline")
check(o7.diagnostics.decodeFailed, "decodeFailed flagged")

// 8) 500 → offline
check(classifyOfficialResponse(data: nil, httpStatus: 500, error: nil).result.telemetryName == "offline", "500 → offline")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swiftc tests/ClassifierTests.swift src/Providers.swift src/Models.swift -o /tmp/clstest 2>&1 | head`
Expected: `error: cannot find 'classifyOfficialResponse' in scope`

- [ ] **Step 3: 구현** — `src/Providers.swift` 편집

3a. `enum OfficialResult { ... }` 정의 **바로 아래**에 추가:

```swift
extension OfficialResult {
    /// 텔레메트리/로그/전이감지용 안정 문자열 (associated value 제외).
    var telemetryName: String {
        switch self {
        case .ok: return "ok"
        case .loading: return "loading"
        case .noToken: return "noToken"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rateLimited"
        case .offline: return "offline"
        }
    }
}

struct OfficialFetchDiagnostics {
    var httpStatus: Int?
    var urlErrorCode: Int?
    var urlErrorDesc: String?
    var decodeFailed: Bool = false
    var bodyWasErrorObject: Bool = false
}

struct OfficialFetchOutcome {
    let result: OfficialResult
    let diagnostics: OfficialFetchDiagnostics
}

/// 순수 분류: 응답을 OfficialResult + 진단정보로 변환. 네트워크 호출 없음(테스트 가능).
func classifyOfficialResponse(data: Data?, httpStatus: Int?, error: Error?) -> OfficialFetchOutcome {
    var d = OfficialFetchDiagnostics()
    d.httpStatus = httpStatus

    guard let status = httpStatus else {
        if let urlErr = error as? URLError {
            d.urlErrorCode = urlErr.errorCode
            d.urlErrorDesc = urlErr.localizedDescription
        }
        return OfficialFetchOutcome(result: .offline, diagnostics: d)
    }
    if status == 401 { return OfficialFetchOutcome(result: .unauthorized, diagnostics: d) }
    if status == 429 { return OfficialFetchOutcome(result: .rateLimited, diagnostics: d) }
    guard (200..<300).contains(status), let data = data else {
        return OfficialFetchOutcome(result: .offline, diagnostics: d)
    }
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let err = obj["error"] as? [String: Any] {
        d.bodyWasErrorObject = true
        let isRate = (err["type"] as? String) == "rate_limit_error"
        return OfficialFetchOutcome(result: isRate ? .rateLimited : .offline, diagnostics: d)
    }
    guard let usage = try? JSONDecoder().decode(OfficialUsage.self, from: data) else {
        d.decodeFailed = true
        return OfficialFetchOutcome(result: .offline, diagnostics: d)
    }
    return OfficialFetchOutcome(result: .ok(usage), diagnostics: d)
}
```

3b. `OfficialUsageProvider.fetch()` **전체를 교체** (반환형 변경 + error 캡처 + 분류함수 사용):

```swift
    /// 동기 호출 (refresh 의 Task.detached 내부에서 사용).
    static func fetch() -> OfficialFetchOutcome {
        guard let token = KeychainToken.read() else {
            return OfficialFetchOutcome(result: .noToken, diagnostics: OfficialFetchDiagnostics())
        }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var outcome = OfficialFetchOutcome(result: .offline, diagnostics: OfficialFetchDiagnostics())
        let dataTask = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode
            outcome = classifyOfficialResponse(data: data, httpStatus: status, error: error)
        }
        dataTask.resume()
        sem.wait()
        return outcome
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swiftc tests/ClassifierTests.swift src/Providers.swift src/Models.swift -o /tmp/clstest && /tmp/clstest`
Expected: 마지막 줄 `ALL PASS`

> 이 시점에 `Store.swift`는 아직 옛 반환형을 기대해 앱 전체 빌드는 깨진다. Task 5에서 호출부를 고친다. 이 태스크의 검증은 위 순수-함수 테스트로 한다.

- [ ] **Step 5: 커밋**

```bash
git add src/Providers.swift tests/ClassifierTests.swift
git commit -m "feat: 공식 fetch 진단 포착 + 순수 분류 함수(classifyOfficialResponse)"
```

---

### Task 3: 로컬 진단 로그 (회전 파일)

**Files:**
- Create: `src/DiagnosticLog.swift`
- Test: `tests/DiagnosticLogTests.swift`

**Interfaces:**
- Consumes: `OfficialFetchOutcome`, `OfficialFetchDiagnostics`, `ProxyStatus`
- Produces:
  - `func diagnosticLogLine(date: Date, outcome: OfficialFetchOutcome, proxy: ProxyStatus, appVersion: String, os: String) -> String`
  - `func diagnosticShouldRotate(currentBytes: Int, cap: Int) -> Bool`
  - `enum DiagnosticLog { static var isEnabled: Bool (get); static func log(outcome:proxy:); static var directoryURL: URL }`

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/DiagnosticLogTests.swift`

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

check(diagnosticShouldRotate(currentBytes: 262_144, cap: 262_144) == true, "rotate at cap")
check(diagnosticShouldRotate(currentBytes: 262_145, cap: 262_144) == true, "rotate over cap")
check(diagnosticShouldRotate(currentBytes: 1000, cap: 262_144) == false, "no rotate under cap")

// 고정 날짜로 라인 포맷 검증 (2026-07-14T14:54:09Z 부근)
let d = Date(timeIntervalSince1970: 1_784_045_649)
var diag = OfficialFetchDiagnostics()
diag.urlErrorCode = -1200
let outcome = OfficialFetchOutcome(result: .offline, diagnostics: diag)
let line = diagnosticLogLine(date: d, outcome: outcome,
                             proxy: ProxyStatus(system: false, env: true),
                             appVersion: "1.0", os: "15.5")
check(line.contains("result=offline"), "line has result")
check(line.contains("urlerr=-1200"), "line has urlErrorCode")
check(line.contains("proxySystem=false"), "line has proxySystem")
check(line.contains("proxyEnv=true"), "line has proxyEnv")
check(!line.lowercased().contains("bearer") && !line.contains("token"), "line has no secret")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swiftc tests/DiagnosticLogTests.swift src/DiagnosticLog.swift src/Providers.swift src/Models.swift src/ProxyStatus.swift src/AppInfo.swift -framework CFNetwork -o /tmp/dltest 2>&1 | head`
Expected: `error: cannot find 'diagnosticShouldRotate' in scope`

- [ ] **Step 3: 구현** — `src/DiagnosticLog.swift`

```swift
import Foundation

// MARK: - 순수 로직 (테스트 대상)

func diagnosticShouldRotate(currentBytes: Int, cap: Int) -> Bool {
    currentBytes >= cap
}

func diagnosticLogLine(date: Date, outcome: OfficialFetchOutcome,
                       proxy: ProxyStatus, appVersion: String, os: String) -> String {
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone.current
    iso.formatOptions = [.withInternetDateTime]
    let d = outcome.diagnostics
    let http = d.httpStatus.map(String.init) ?? "nil"
    let urlerr = d.urlErrorCode.map(String.init) ?? "nil"
    return "\(iso.string(from: date)) result=\(outcome.result.telemetryName) "
        + "http=\(http) urlerr=\(urlerr) "
        + "proxySystem=\(proxy.system) proxyEnv=\(proxy.env) "
        + "decodeFailed=\(d.decodeFailed) v=\(appVersion) os=\(os)"
}

// MARK: - 파일 로거 (부수효과, try? 로 조용히 실패)

enum DiagnosticLog {
    static let defaultsKey = "diagnosticLoggingEnabled"
    static let cap = 262_144   // 256KB
    private static let queue = DispatchQueue(label: "com.jeongjieun.ClaudeUsageMonitor.diaglog")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/ClaudeUsageMonitor", isDirectory: true)
    }
    private static var fileURL: URL { directoryURL.appendingPathComponent("monitor.log") }
    private static var rotatedURL: URL { directoryURL.appendingPathComponent("monitor.log.1") }

    static func log(outcome: OfficialFetchOutcome, proxy: ProxyStatus) {
        guard isEnabled else { return }   // off면 파일 접근조차 안 함
        let line = diagnosticLogLine(
            date: Date(), outcome: outcome, proxy: proxy,
            appVersion: appVersionString(), os: osVersionString()) + "\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL)   // 파일이 없으면 새로 생성
                }
            }
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard let bytes = size, diagnosticShouldRotate(currentBytes: bytes, cap: cap) else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }
}
```

> `appVersionString()` / `osVersionString()`는 Task 1의 `src/AppInfo.swift`에 이미 정의돼 있다(중복 정의 금지).

- [ ] **Step 4: 테스트 통과 확인**

Run: `swiftc tests/DiagnosticLogTests.swift src/DiagnosticLog.swift src/Providers.swift src/Models.swift src/ProxyStatus.swift src/AppInfo.swift -framework CFNetwork -o /tmp/dltest && /tmp/dltest`
Expected: 마지막 줄 `ALL PASS`

- [ ] **Step 5: 커밋**

```bash
git add src/DiagnosticLog.swift tests/DiagnosticLogTests.swift
git commit -m "feat: 로컬 진단 로그(회전 파일, 256KB×2) 추가"
```

---

### Task 4: 익명 텔레메트리 래퍼 (HTTP ingest POST, 의존성 0)

**Files:**
- Create: `src/Telemetry.swift`
- Test: `tests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `OfficialFetchOutcome`, `ProxyStatus`
- Produces:
  - `func telemetryShouldEmit(previous: String?, current: String, firstOfSession: Bool) -> Bool`
  - `func telemetryInstallID(_ defaults: UserDefaults) -> String`
  - `func telemetryPayload(installID: String, outcome: OfficialFetchOutcome, proxy: ProxyStatus, appVersion: String, os: String) -> [String: Any]`
  - `enum Telemetry { static var isEnabled: Bool; static func trackOfficialResult(outcome:proxy:previous:firstOfSession:) }`

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/TelemetryTests.swift`

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// 전송 게이트: 전이 또는 세션최초일 때만
check(telemetryShouldEmit(previous: nil, current: "ok", firstOfSession: true) == true, "first of session emits")
check(telemetryShouldEmit(previous: "ok", current: "offline", firstOfSession: false) == true, "transition emits")
check(telemetryShouldEmit(previous: "offline", current: "offline", firstOfSession: false) == false, "same state no emit")

// installID: 최초 생성 후 고정
let d = UserDefaults(suiteName: "telemetry.test.\(UUID().uuidString)")!
let id1 = telemetryInstallID(d)
let id2 = telemetryInstallID(d)
check(id1 == id2, "installID stable")
check(UUID(uuidString: id1) != nil, "installID is uuid")

// payload: 진단 필드만, 비밀 없음
var diag = OfficialFetchDiagnostics(); diag.httpStatus = 407
let p = telemetryPayload(installID: id1,
                         outcome: OfficialFetchOutcome(result: .offline, diagnostics: diag),
                         proxy: ProxyStatus(system: false, env: true),
                         appVersion: "1.0", os: "15.5")
check(p["result"] as? String == "offline", "payload result")
check(p["httpStatus"] as? Int == 407, "payload httpStatus")
check(p["proxyEnv"] as? Bool == true, "payload proxyEnv")
let flat = "\(p)".lowercased()
check(!flat.contains("bearer") && !flat.contains("token") && !flat.contains("authorization"), "payload has no secret")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swiftc tests/TelemetryTests.swift src/Telemetry.swift src/Providers.swift src/Models.swift src/ProxyStatus.swift src/AppInfo.swift -framework CFNetwork -o /tmp/tmtest 2>&1 | head`
Expected: `error: cannot find 'telemetryShouldEmit' in scope`

- [ ] **Step 3: 구현** — `src/Telemetry.swift`

```swift
import Foundation

// MARK: - 순수 로직 (테스트 대상)

func telemetryShouldEmit(previous: String?, current: String, firstOfSession: Bool) -> Bool {
    firstOfSession || previous != current
}

func telemetryInstallID(_ defaults: UserDefaults) -> String {
    let key = "telemetryInstallID"
    if let existing = defaults.string(forKey: key) { return existing }
    let id = UUID().uuidString          // 익명. 계정/기기 식별정보 아님.
    defaults.set(id, forKey: key)
    return id
}

func telemetryPayload(installID: String, outcome: OfficialFetchOutcome,
                      proxy: ProxyStatus, appVersion: String, os: String) -> [String: Any] {
    let d = outcome.diagnostics
    var p: [String: Any] = [
        "installID": installID,
        "result": outcome.result.telemetryName,
        "proxySystem": proxy.system,
        "proxyEnv": proxy.env,
        "decodeFailed": d.decodeFailed,
        "appVersion": appVersion,
        "os": os,
    ]
    if let s = d.httpStatus { p["httpStatus"] = s }
    if let c = d.urlErrorCode { p["urlErrorCode"] = c }
    return p
}

// MARK: - 전송 (부수효과)

enum Telemetry {
    static let defaultsKey = "telemetryEnabled"

    // 제공자 계정 생성 후 발급받는 값. Step 3 노트 참조.
    // 실제 ingest 엔드포인트/스키마는 계정 생성 후 context7/공식 문서로 확정한다.
    static let ingestEndpoint = URL(string: "https://REPLACE-WITH-INGEST-HOST/v0/event")!
    static let appID = "REPLACE-WITH-APP-ID"

    static var isEnabled: Bool {
        // 키가 없으면 기본 on(opt-out).
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            ? true : UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func trackOfficialResult(outcome: OfficialFetchOutcome, proxy: ProxyStatus,
                                    previous: String?, firstOfSession: Bool) {
        guard isEnabled else { return }
        guard telemetryShouldEmit(previous: previous,
                                  current: outcome.result.telemetryName,
                                  firstOfSession: firstOfSession) else { return }
        let payload = telemetryPayload(
            installID: telemetryInstallID(.standard),
            outcome: outcome, proxy: proxy,
            appVersion: appVersionString(), os: osVersionString())
        send(payload)
    }

    private static func send(_ payload: [String: Any]) {
        // 제공자 스키마에 맞춰 body 구성. 아래는 자체 엔드포인트/일반 REST ingest 기준 예시.
        var body = payload
        body["appID"] = appID
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: ingestEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        // fire-and-forget. 실패는 무시(앱 무영향).
        URLSession.shared.dataTask(with: req).resume()
    }
}
```

> **Step 3 노트 (외부 설정 — 이 태스크의 유일한 비-코드 의존성):**
> `ingestEndpoint`/`appID`/`send()`의 body 스키마는 선택한 제공자에 따라 확정한다.
> 1. TelemetryDeck 또는 Aptabase 계정 생성 → App ID 발급 (또는 자체 엔드포인트 준비).
> 2. context7로 `resolve-library-id` → 해당 제공자 **HTTP ingest API** 문서 조회 → 엔드포인트 URL과 JSON 스키마 확정.
> 3. `REPLACE-WITH-*` 상수와 `send()` body를 그 스키마에 맞게 채운다.
> (순수 함수 3종은 제공자와 무관하게 이미 완성·테스트됨.)

- [ ] **Step 4: 테스트 통과 확인** (순수 함수만 검증. 네트워크 전송은 런타임에서.)

Run: `swiftc tests/TelemetryTests.swift src/Telemetry.swift src/Providers.swift src/Models.swift src/ProxyStatus.swift src/AppInfo.swift -framework CFNetwork -o /tmp/tmtest && /tmp/tmtest`
Expected: 마지막 줄 `ALL PASS`

- [ ] **Step 5: 커밋**

```bash
git add src/Telemetry.swift tests/TelemetryTests.swift
git commit -m "feat: 익명 텔레메트리 래퍼(전이 게이트/installID/payload) 추가"
```

---

### Task 5: Store 통합 — fetch 결과 처리부에서 두 레이어 호출

**Files:**
- Modify: `src/Store.swift` (refresh의 `Task.detached` 내부, 현재 107~168행 영역)

**Interfaces:**
- Consumes: `OfficialUsageProvider.fetch() -> OfficialFetchOutcome`, `currentProxyStatus()`, `DiagnosticLog.log`, `Telemetry.trackOfficialResult`, 기존 `officialState`

- [ ] **Step 1: 세션 플래그 프로퍼티 추가**

`Store` 클래스 내부(다른 `private var` 근처)에 추가:

```swift
    private var didEmitSessionTelemetry = false
```

- [ ] **Step 2: fetch 호출부 수정**

현재 118행 근처:
```swift
            let off = shouldFetchOfficial ? OfficialUsageProvider.fetch() : currentOfficialState
```
을 아래로 교체 (fetch는 이제 Outcome 반환. 실제 fetch일 때만 진단 수집):
```swift
            let outcome: OfficialFetchOutcome? = shouldFetchOfficial ? OfficialUsageProvider.fetch() : nil
            let off = outcome?.result ?? currentOfficialState
```

- [ ] **Step 3: 결과 적용부에서 이전 상태 캡처 + 두 레이어 호출**

`updateOfficialCooldown(after: off)` 호출(현재 167행) **직전**에, 그리고 `officialState`가 갱신되기 전에 아래를 삽입. (`officialState` 갱신 라인이 이 근처에 있음 — 갱신 전에 `previous`를 읽어야 함.)

```swift
            // 진단 관측: 실제 fetch가 일어난 경우에만
            if let outcome {
                let previousName = self.officialState.telemetryName
                let proxy = currentProxyStatus()
                DiagnosticLog.log(outcome: outcome, proxy: proxy)
                Telemetry.trackOfficialResult(
                    outcome: outcome, proxy: proxy,
                    previous: previousName,
                    firstOfSession: !self.didEmitSessionTelemetry)
                self.didEmitSessionTelemetry = true
            }
```

> 주의: 이 블록은 `officialState = off`(상태 갱신) **이전에** 실행돼야 `previousName`이 직전 값이 된다. 갱신 라인 순서를 확인해 그 앞에 배치할 것. `self`가 `Task.detached`의 `[weak self]`라면 `guard let self`로 언랩된 스코프 안에 둔다.

- [ ] **Step 4: 전체 앱 빌드 확인**

Run: `./build.sh --no-install`
Expected: `▶ 컴파일 (swiftc -O)…` 이후 에러 없이 완료(서명까지). Task 2에서 깨졌던 호출부가 복구됨.

- [ ] **Step 5: 런타임 확인 (로컬 로그)**

```bash
# 설정 토글 대신 임시로 로그를 강제 on 후 앱 실행
defaults write com.jeongjieun.ClaudeUsageMonitor diagnosticLoggingEnabled -bool true
open dist/ClaudeUsageMonitor.app
sleep 65   # 폴링 1~2회
cat ~/Library/Logs/ClaudeUsageMonitor/monitor.log
```
Expected: `result=... proxySystem=... proxyEnv=...` 형태 라인이 최소 1줄. 토큰 문자열 없음.

- [ ] **Step 6: 커밋**

```bash
git add src/Store.swift
git commit -m "feat: Store fetch 처리부에서 진단 로그·텔레메트리 호출(전이 감지)"
```

---

### Task 6: 설정 UI — 진단 섹션

**Files:**
- Modify: `src/Views.swift` (설정 시트 뷰)

**Interfaces:**
- Consumes: `store.telemetryEnabled`, `store.diagnosticLoggingEnabled`(Task 5에서 노출), `DiagnosticLog.directoryURL`

- [ ] **Step 1: Store에 토글 바인딩 노출**

`src/Store.swift`에 `@Published` 프로퍼티 + setter 추가 (기존 `defaults.set(...forKey:)` 패턴):

```swift
    @Published var telemetryEnabled: Bool
    @Published var diagnosticLoggingEnabled: Bool
```
`init`에서 로드(텔레메트리는 기본 on):
```swift
        self.telemetryEnabled = defaults.object(forKey: Telemetry.defaultsKey) == nil
            ? true : defaults.bool(forKey: Telemetry.defaultsKey)
        self.diagnosticLoggingEnabled = defaults.bool(forKey: DiagnosticLog.defaultsKey)
```
setter:
```swift
    func setTelemetryEnabled(_ on: Bool) {
        telemetryEnabled = on
        defaults.set(on, forKey: Telemetry.defaultsKey)
    }
    func setDiagnosticLoggingEnabled(_ on: Bool) {
        diagnosticLoggingEnabled = on
        defaults.set(on, forKey: DiagnosticLog.defaultsKey)
    }
```

- [ ] **Step 2: 설정 뷰에 "진단" 섹션 추가**

설정 시트 본문의 기존 섹션들 **마지막 근처**에 아래 SwiftUI 블록 삽입. (주변 섹션의 폰트·간격 스타일에 맞춰 `Text`/`Toggle` 모디파이어를 동일 패턴으로 조정.)

```swift
            VStack(alignment: .leading, spacing: 8) {
                Text("진단")
                    .font(.headline)

                Toggle("익명 사용 진단 보내기", isOn: Binding(
                    get: { store.telemetryEnabled },
                    set: { store.setTelemetryEnabled($0) }))
                Text("문제 발생률·환경(프록시 등)만 익명으로 집계합니다. 토큰·사용량 내용은 전송하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("로컬 진단 로그 기록", isOn: Binding(
                    get: { store.diagnosticLoggingEnabled },
                    set: { store.setDiagnosticLoggingEnabled($0) }))

                Button("로그 폴더 열기") {
                    let dir = DiagnosticLog.directoryURL
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                .font(.caption)
            }
```

- [ ] **Step 3: 빌드 확인**

Run: `./build.sh --no-install`
Expected: 컴파일 에러 없이 완료.

- [ ] **Step 4: 런타임 확인 (설정 UI)**

```bash
open dist/ClaudeUsageMonitor.app
```
Expected: 설정 시트에 "진단" 섹션, 토글 2개, "로그 폴더 열기" 버튼. 로컬 로그 토글이 off 기본, 텔레메트리 on 기본. "로그 폴더 열기" 클릭 시 Finder로 `~/Library/Logs/ClaudeUsageMonitor` 열림.

- [ ] **Step 5: 커밋**

```bash
git add src/Store.swift src/Views.swift
git commit -m "feat: 설정에 진단 섹션(텔레메트리/로컬로그 토글 + 폴더 열기)"
```

---

### Task 7: README 개인정보 고지 + 최종 검증

**Files:**
- Modify: `README.md` (## 개인정보 섹션)

- [ ] **Step 1: 개인정보 섹션에 익명 진단 고지 추가**

`## 개인정보` 섹션의 기존 항목 아래에 추가:

```markdown
- **익명 진단(기본 on, 끌 수 있음)**: 앱은 공식 사용량 조회의 **결과 분류·HTTP 상태·프록시 사용 여부·앱/OS 버전**만
  익명으로 전송해 배포판 이슈를 파악합니다. **토큰·사용량 수치·계정 식별정보는 전송하지 않습니다.**
  `설정 → 진단`에서 언제든 끌 수 있습니다.
- **로컬 진단 로그(기본 off)**: 켜면 `~/Library/Logs/ClaudeUsageMonitor/` 에 조회 결과를 남깁니다(로컬 저장, 최대 512KB). 외부 전송 없음.
```

- [ ] **Step 2: 전체 테스트 재실행 (회귀 확인)**

```bash
swiftc tests/ProxyStatusTests.swift src/ProxyStatus.swift -framework CFNetwork -o /tmp/t1 && /tmp/t1
swiftc tests/ClassifierTests.swift src/Providers.swift src/Models.swift -o /tmp/t2 && /tmp/t2
swiftc tests/DiagnosticLogTests.swift src/DiagnosticLog.swift src/Providers.swift src/Models.swift src/ProxyStatus.swift src/AppInfo.swift -framework CFNetwork -o /tmp/t3 && /tmp/t3
swiftc tests/TelemetryTests.swift src/Telemetry.swift src/Providers.swift src/Models.swift src/ProxyStatus.swift src/AppInfo.swift -framework CFNetwork -o /tmp/t4 && /tmp/t4
```
Expected: 4개 모두 `ALL PASS`.

- [ ] **Step 3: 최종 빌드**

Run: `./build.sh`
Expected: 컴파일·서명·설치 완료.

- [ ] **Step 4: 커밋**

```bash
git add README.md
git commit -m "docs: README에 익명 진단·로컬 로그 개인정보 고지 추가"
```

---

## 남은 외부 작업 (코드 밖)
- Task 4 노트대로 텔레메트리 제공자 계정 생성 → `ingestEndpoint`/`appID`/`send()` body 스키마 확정(context7).
- 임시 강제 토글 해제: `defaults delete com.jeongjieun.ClaudeUsageMonitor diagnosticLoggingEnabled`
- (후속·범위 밖) 다수 배포 시 notarization 검토.
